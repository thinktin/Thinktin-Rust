//! 账号、设备会话、运行授权的完整流程。需要 DATABASE_URL（没有时跳过）。

use std::sync::Arc;
use std::time::Duration;

use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier};
use auth::service::{AuthConfig, AuthError, AuthService, Login, NewDevice, Principal};
use auth::signed::{Signer25519, Verifier25519};
use auth::sms::{CodePurpose, RecordingSms};
use proto::domain::{DevicePlatform, GrantScope, InstanceLimits, InstanceState, PushChannelKind};
use store::NewInstance;
use store::testing::TestDb;
use zeroize::Zeroizing;

const PHONE: &str = "138 0013 8000";
const E164: &str = "+8613800138000";

fn service(t: &TestDb, grace: Duration) -> (AuthService, Arc<RecordingSms>) {
    let signer = Signer25519::generate("k1").unwrap();
    let mut verifier = Verifier25519::new();
    verifier
        .add_key_b64("k1", &signer.verifying_key_b64())
        .unwrap();
    let sms = Arc::new(RecordingSms::default());
    let svc = AuthService::new(
        t.db.clone(),
        AuthConfig {
            code_resend_interval: Duration::ZERO,
            refresh_reuse_grace: grace,
            ..AuthConfig::default()
        },
        Zeroizing::new(vec![7u8; 32]),
        AccessTokenIssuer(signer),
        AccessTokenVerifier(verifier),
        sms.clone(),
    )
    .unwrap();
    (svc, sms)
}

fn phone_device(name: &str) -> NewDevice {
    NewDevice {
        platform: DevicePlatform::Ios,
        name: name.into(),
        push: Some((PushChannelKind::Apns, format!("apns-{name}"))),
    }
}

async fn login(svc: &AuthService, sms: &RecordingSms, device: &str) -> Login {
    svc.send_code(PHONE, CodePurpose::Login).await.unwrap();
    let code = sms.last_code(E164).unwrap();
    svc.login(PHONE, &code, &phone_device(device))
        .await
        .unwrap()
}

async fn principal(svc: &AuthService, l: &Login) -> Principal {
    svc.authenticate(&l.tokens.access_token).await.unwrap()
}

#[tokio::test]
async fn login_refresh_and_reuse_detection() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::ZERO);

    assert!(matches!(
        svc.send_code("12345", CodePurpose::Login).await,
        Err(AuthError::InvalidPhone)
    ));
    svc.send_code(PHONE, CodePurpose::Login).await.unwrap();
    let code = sms.last_code(E164).unwrap();
    assert_eq!(code.len(), 6);
    let wrong = if code == "000000" { "000001" } else { "000000" };
    assert!(matches!(
        svc.login(PHONE, wrong, &phone_device("a")).await,
        Err(AuthError::InvalidCode)
    ));
    let l = svc.login(PHONE, &code, &phone_device("a")).await.unwrap();
    assert!(l.new_user);
    assert_eq!(l.user.phone, E164);
    assert!(
        matches!(
            svc.login(PHONE, &code, &phone_device("b")).await,
            Err(AuthError::InvalidCode)
        ),
        "a code works once"
    );
    let p = principal(&svc, &l).await;
    assert_eq!(
        (p.user, p.device, p.session),
        (l.user.id, l.device_id, l.session_id)
    );

    // 轮换：新令牌能用；旧令牌再用一次 = 被盗信号，整个会话吊销。
    let t2 = svc.refresh(&l.tokens.refresh_token).await.unwrap();
    assert_ne!(*t2.refresh_token, *l.tokens.refresh_token);
    svc.authenticate(&t2.access_token).await.unwrap();
    assert!(matches!(
        svc.refresh(&l.tokens.refresh_token).await,
        Err(AuthError::SessionRevoked)
    ));
    assert!(matches!(
        svc.refresh(&t2.refresh_token).await,
        Err(AuthError::SessionRevoked)
    ));
    assert!(matches!(
        svc.authenticate(&t2.access_token).await,
        Err(AuthError::SessionRevoked)
    ));
    // 乱写的令牌只是认证失败，不会吊销别人的会话。
    let again = login(&svc, &sms, "a2").await;
    assert!(!again.new_user);
    let forged = format!("rtk1.{}.{}", again.session_id, "A".repeat(43));
    assert!(matches!(
        svc.refresh(&forged).await,
        Err(AuthError::Unauthenticated)
    ));
    svc.refresh(&again.tokens.refresh_token).await.unwrap();
    assert!(matches!(
        svc.authenticate("tta1.k1.e30.AAAA").await,
        Err(AuthError::Unauthenticated)
    ));
}

#[tokio::test]
async fn concurrent_refresh_within_grace_is_allowed() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::from_secs(30));
    let l = login(&svc, &sms, "a").await;
    let t2 = svc.refresh(&l.tokens.refresh_token).await.unwrap();
    // 另一个并发请求还拿着旧令牌：轮换刚发生，放行。
    let t3 = svc.refresh(&l.tokens.refresh_token).await.unwrap();
    svc.authenticate(&t3.access_token).await.unwrap();
    // 先回来的那个令牌现在是“上一个”，同样在宽限期内。
    svc.refresh(&t2.refresh_token).await.unwrap();
}

#[tokio::test]
async fn code_attempts_and_rate_limits() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::ZERO);
    svc.send_code(PHONE, CodePurpose::Login).await.unwrap();
    let code = sms.last_code(E164).unwrap();
    let wrong = if code == "000000" { "000001" } else { "000000" };
    for _ in 0..auth::secrets::CODE_MAX_ATTEMPTS {
        assert!(matches!(
            svc.login(PHONE, wrong, &phone_device("a")).await,
            Err(AuthError::InvalidCode)
        ));
    }
    assert!(
        matches!(
            svc.login(PHONE, &code, &phone_device("a")).await,
            Err(AuthError::InvalidCode)
        ),
        "the code is burned after too many attempts"
    );
    // 新码作废旧码；一种用途的码不能用于另一种。
    svc.send_code(PHONE, CodePurpose::DeleteAccount)
        .await
        .unwrap();
    let delete_code = sms.last_code(E164).unwrap();
    assert!(matches!(
        svc.login(PHONE, &delete_code, &phone_device("a")).await,
        Err(AuthError::InvalidCode)
    ));

    // 限频：间隔、每日上限。
    let (strict, strict_sms) = {
        let signer = Signer25519::generate("k1").unwrap();
        let sms = Arc::new(RecordingSms::default());
        (
            AuthService::new(
                t.db.clone(),
                AuthConfig {
                    code_daily_limit: 3,
                    ..AuthConfig::default()
                },
                Zeroizing::new(vec![7u8; 32]),
                AccessTokenIssuer(signer),
                AccessTokenVerifier::default(),
                sms.clone(),
            )
            .unwrap(),
            sms,
        )
    };
    match strict.send_code(PHONE, CodePurpose::Login).await {
        Err(AuthError::TooManyCodes { retry_after_secs }) => assert!(retry_after_secs > 0),
        other => panic!("expected rate limit, got {other:?}"),
    }
    assert!(matches!(
        strict.send_code("13900000000", CodePurpose::Login).await,
        Ok(())
    ));
    assert_eq!(strict_sms.count(), 1);
    assert_eq!(sms.count(), 2);
}

#[tokio::test]
async fn devices_logout_and_remote_logout() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::ZERO);
    let phone_login = login(&svc, &sms, "iphone").await;
    let mac_login = login(&svc, &sms, "mac").await;
    let phone = principal(&svc, &phone_login).await;
    let mac = principal(&svc, &mac_login).await;
    assert_eq!(phone.user, mac.user);

    let mut tx = t.db.tenant(phone.user).await.unwrap();
    assert_eq!(tx.devices().await.unwrap().len(), 2);
    tx.rollback().await.unwrap();

    // 手机把电脑远程下线：电脑的令牌都失效，手机不受影响。
    svc.revoke_device(&phone, mac.device).await.unwrap();
    assert!(matches!(
        svc.authenticate(&mac_login.tokens.access_token).await,
        Err(AuthError::SessionRevoked)
    ));
    assert!(matches!(
        svc.refresh(&mac_login.tokens.refresh_token).await,
        Err(AuthError::SessionRevoked)
    ));
    svc.authenticate(&phone_login.tokens.access_token)
        .await
        .unwrap();
    let mut tx = t.db.tenant(phone.user).await.unwrap();
    let devices = tx.devices().await.unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].push_channel, Some(PushChannelKind::Apns));
    tx.rollback().await.unwrap();

    // 别人的设备下线不了。
    let (other_svc, other_sms) = (svc, sms);
    other_sms.count();
    other_svc
        .send_code("13900000000", CodePurpose::Login)
        .await
        .unwrap();
    let code = other_sms.last_code("+8613900000000").unwrap();
    let stranger = other_svc
        .login("13900000000", &code, &phone_device("x"))
        .await
        .unwrap();
    let stranger = principal(&other_svc, &stranger).await;
    assert!(matches!(
        other_svc.revoke_device(&stranger, phone.device).await,
        Err(AuthError::NotFound)
    ));

    other_svc.logout(&phone).await.unwrap();
    assert!(matches!(
        other_svc
            .authenticate(&phone_login.tokens.access_token)
            .await,
        Err(AuthError::SessionRevoked)
    ));
}

fn grant_service(t: &TestDb) -> (GrantService, SandboxTokenVerifier) {
    let issuer = SandboxTokenIssuer::generate("s1").unwrap();
    let mut verifier = SandboxTokenVerifier::new();
    verifier
        .add_key_b64("s1", &issuer.verifying_key_b64())
        .unwrap();
    (
        GrantService::new(t.db.clone(), GrantConfig::default(), issuer),
        verifier,
    )
}

async fn running_instance(t: &TestDb, who: &Principal) -> proto::domain::InstanceId {
    let mut tx = t.db.tenant(who.user).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "main".into(),
            workspace_id: "vol".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut w = t.db.worker().await.unwrap();
    w.set_instance_runtime(
        inst.id,
        InstanceState::Running,
        Some("sbx-1"),
        Some("10.0.0.7".parse().unwrap()),
        None,
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    inst.id
}

#[tokio::test]
async fn grants_outlive_logout_but_not_freeze_or_revocation() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::ZERO);
    let (grants, verifier) = grant_service(&t);
    let l = login(&svc, &sms, "iphone").await;
    let who = principal(&svc, &l).await;
    let instance = running_instance(&t, &who).await;
    let scope = GrantScope {
        aliases: vec!["main".into(), "fast".into()],
        platform_tools: vec!["schedule_list".into()],
        max_tokens: Some(1_000_000),
    };
    let grant = grants.issue(&who, instance, None, &scope).await.unwrap();

    // 退出登录不影响 agent：照样能换沙箱令牌。
    svc.logout(&who).await.unwrap();
    let cred = grants.sandbox_token(grant.id, instance).await.unwrap();
    let claims = verifier.verify(&cred.token, now()).unwrap();
    assert_eq!(claims.sbx, "sbx-1");
    assert_eq!(claims.net.as_deref(), Some("10.0.0.7"));
    assert_eq!(claims.grant, grant.id.to_string());
    assert_eq!(claims.uid, who.user.to_string());
    assert_eq!(cred.expires_in, Duration::from_secs(24 * 3600));
    let mut w = t.db.worker().await.unwrap();
    let (_, touched) = w.run_grant(grant.id).await.unwrap();
    assert!(touched.last_used_at.is_some());

    // 子授权只能收窄；吊销父授权连带子授权。
    let narrower = GrantScope {
        aliases: vec!["fast".into()],
        platform_tools: vec![],
        max_tokens: Some(1000),
    };
    let child = w
        .create_child_grant(grant.id, instance, &narrower, Duration::from_secs(3600))
        .await
        .unwrap();
    assert_eq!(child.parent_id, Some(grant.id));
    assert!(matches!(
        w.create_child_grant(
            grant.id,
            instance,
            &GrantScope::default(),
            Duration::from_secs(60)
        )
        .await,
        Err(store::Error::Invalid(_))
    ));
    w.commit().await.unwrap();

    // 冻结：换不出令牌；解冻后恢复。
    svc.set_frozen(who.user, true, "risk").await.unwrap();
    assert!(matches!(
        grants.sandbox_token(grant.id, instance).await,
        Err(AuthError::AccountFrozen)
    ));
    svc.send_code(PHONE, CodePurpose::Login).await.unwrap();
    let code = sms.last_code(E164).unwrap();
    assert!(matches!(
        svc.login(PHONE, &code, &phone_device("x")).await,
        Err(AuthError::AccountFrozen)
    ));
    svc.set_frozen(who.user, false, "cleared").await.unwrap();
    grants.sandbox_token(grant.id, instance).await.unwrap();

    // 用户吊销：令牌换不出来了，子授权一起失效。
    let l2 = login(&svc, &sms, "iphone").await;
    let who2 = principal(&svc, &l2).await;
    assert_eq!(grants.revoke(&who2, grant.id, "stop").await.unwrap(), 2);
    assert!(matches!(
        grants.sandbox_token(grant.id, instance).await,
        Err(AuthError::Invalid(_))
    ));
    assert!(grants.sandbox_token(child.id, instance).await.is_err());
    // 授权不能拿去给别的实例换令牌。
    let other = running_instance(&t, &who2).await;
    let g2 = grants.issue(&who2, other, None, &scope).await.unwrap();
    assert!(matches!(
        grants.sandbox_token(g2.id, instance).await,
        Err(AuthError::Invalid(_))
    ));
}

#[tokio::test]
async fn delete_account_erases_everything() {
    let Some(t) = TestDb::new().await else { return };
    let (svc, sms) = service(&t, Duration::ZERO);
    let (grants, _) = grant_service(&t);
    let l = login(&svc, &sms, "iphone").await;
    let who = principal(&svc, &l).await;
    let instance = running_instance(&t, &who).await;
    let grant = grants
        .issue(&who, instance, None, &GrantScope::default())
        .await
        .unwrap();
    let mut w = t.db.worker().await.unwrap();
    sqlx_insert_user_key(&mut w, who.user).await;
    w.commit().await.unwrap();

    // 注销要用发到本人手机的专用验证码，登录码不行。
    svc.send_code_to_self(&who, CodePurpose::DeleteAccount)
        .await
        .unwrap();
    let code = sms.last_code(E164).unwrap();
    svc.delete_account(&who, &code).await.unwrap();

    assert!(matches!(
        svc.authenticate(&l.tokens.access_token).await,
        Err(AuthError::SessionRevoked)
    ));
    assert!(grants.sandbox_token(grant.id, instance).await.is_err());
    let mut w = t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(instance).await.unwrap().state,
        InstanceState::Deleted
    );
    assert!(!user_key_exists(&mut w, who.user).await);
    w.rollback().await.unwrap();
    // 同一个手机号可以重新注册，是一个全新的账号。
    let fresh = login(&svc, &sms, "iphone").await;
    assert!(fresh.new_user);
    assert_ne!(fresh.user.id, who.user);
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

async fn sqlx_insert_user_key(w: &mut store::Tx<store::Worker>, user: proto::domain::UserId) {
    w.insert_user_key(user, "local", &[1, 2, 3]).await.unwrap();
}

async fn user_key_exists(w: &mut store::Tx<store::Worker>, user: proto::domain::UserId) -> bool {
    w.user_key(user).await.unwrap().is_some()
}
