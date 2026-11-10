//! 用真的 [`AcsProvider`] 连一次 ACS 集群里的 sandbox-manager（docs/sandbox-acs.md 第 8 节的实测条目）：
//! 建沙箱 → 看地址 → 读写文件 → 跑命令（stdin、关 stdin、环境变量、工作目录）→ 长时间没输出 → 从沙箱连模型网关的端口 →
//! 暂停、恢复 → 大文件 → 空闲几分钟（never-timeout）→ 删除。每一步打印结果和用时，出错接着做后面的，最后一定删沙箱。
//!
//! 要在集群 VPC 里的机器上跑（服务机）：
//!
//! ```sh
//! ACS_API_URL=http://<sandbox-manager 的地址>:7788/kruise/api ACS_API_KEY=… ACS_TEMPLATE=code-interpreter \
//!   ACS_ROOT=/home/user ACS_GATEWAY=172.16.0.168:8790 ACS_IDLE_SECS=330 ./acs_probe
//! ```
//!
//! `ACS_ROOT`：测试镜像里没有 `/sandbox`，用 `user` 写得了的目录。`ACS_GATEWAY`：从沙箱里连一下这个 `地址:端口`
//! （服务机上临时开个监听，看它看到的来源地址是不是沙箱的 Pod IP）。`ACS_IDLE_SECS`：建好后空闲多久再看沙箱还在不在。

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use sandbox::acs::{AcsConfig, AcsProvider};
use sandbox::{CreateSpec, EnvValue, ExecSpec, SandboxId, SandboxProvider, SandboxState};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

fn record(item: &str, result: impl std::fmt::Display) {
    println!("- {item}：{result}");
}

struct Output {
    stdout: String,
    stderr: String,
    exit: String,
}

/// 跑一条命令，把 `input` 写进 stdin 后关掉，读完输出等它退出。
async fn run(
    p: &AcsProvider,
    id: &SandboxId,
    argv: &[&str],
    env: &[(&str, &str)],
    input: Option<&str>,
    limit: Duration,
) -> Result<Output, String> {
    let spec = ExecSpec {
        argv: argv.iter().map(|s| s.to_string()).collect(),
        env: env
            .iter()
            .map(|(k, v)| (k.to_string(), EnvValue::Plain(v.to_string())))
            .collect(),
        cwd: None,
    };
    let work = async {
        let mut proc = p.exec(id, spec).await.map_err(|e| format!("exec: {e}"))?;
        if let Some(text) = input {
            proc.stdin
                .write_all(text.as_bytes())
                .await
                .map_err(|e| format!("stdin write: {e}"))?;
        }
        proc.stdin
            .shutdown()
            .await
            .map_err(|e| format!("stdin close: {e}"))?;
        let (mut out, mut err) = (String::new(), String::new());
        let (a, b) = tokio::join!(
            proc.stdout.read_to_string(&mut out),
            proc.stderr.read_to_string(&mut err)
        );
        a.map_err(|e| format!("stdout: {e}"))?;
        b.map_err(|e| format!("stderr: {e}"))?;
        let status = proc
            .control
            .wait()
            .await
            .map_err(|e| format!("wait: {e}"))?;
        Ok::<_, String>(Output {
            stdout: out.trim().to_owned(),
            stderr: err.trim().to_owned(),
            exit: format!("{status}"),
        })
    };
    tokio::time::timeout(limit, work)
        .await
        .map_err(|_| format!("超过 {} 秒没结束", limit.as_secs()))?
}

fn one_line(s: &str) -> String {
    let s = s.replace('\n', " | ");
    if s.chars().count() > 300 {
        format!("{}…", s.chars().take(300).collect::<String>())
    } else {
        s
    }
}

async fn probe(p: &AcsProvider, id: &SandboxId, first_address: Option<std::net::IpAddr>) {
    // 读写文件：顺便把工作目录和 HOME 建出来（envd 上传时建上级目录）。
    let token = format!("thinktin {id}");
    let t = Instant::now();
    let wrote = async {
        p.write_file(id, "workspace/probe.txt", token.as_bytes())
            .await?;
        p.write_file(id, "home/.keep", b"").await?;
        p.read_file(id, "workspace/probe.txt", 1 << 20).await
    }
    .await;
    match wrote {
        Ok(back) if back == token.as_bytes() => record(
            "读写文件",
            format!("通过（{:.1} 秒）", t.elapsed().as_secs_f32()),
        ),
        Ok(_) => record("读写文件", "读回来的内容不一致"),
        Err(e) => record("读写文件", format!("失败：{e}")),
    }
    match p.read_file(id, "workspace/probe.txt", 4).await {
        Err(e) => record("读文件超过上限", format!("拒绝了（{e}）")),
        Ok(b) => record(
            "读文件超过上限",
            format!("没拒绝，读到 {} 字节（应该拒绝）", b.len()),
        ),
    }

    // 命令：stdin、关 stdin、stderr、退出码。
    let t = Instant::now();
    match run(
        p,
        id,
        &[
            "sh",
            "-c",
            "echo out; echo err >&2; cat; echo after-stdin; exit 7",
        ],
        &[],
        Some("hello from stdin\n"),
        Duration::from_secs(60),
    )
    .await
    {
        Ok(o) => record(
            "命令（stdin、关 stdin、stderr、退出码 7）",
            format!(
                "stdout「{}」stderr「{}」{}（{:.1} 秒）",
                one_line(&o.stdout),
                one_line(&o.stderr),
                o.exit,
                t.elapsed().as_secs_f32()
            ),
        ),
        Err(e) => record(
            "命令（stdin、关 stdin、stderr、退出码 7）",
            format!("失败：{e}"),
        ),
    }
    match run(
        p,
        id,
        &[
            "sh",
            "-c",
            "echo \"$FOO\"; pwd; id -un; echo \"$HOME\"; command -v tar python3 curl | tr '\\n' ' '; tar --version 2>/dev/null | head -1",
        ],
        &[("FOO", "bar baz")],
        None,
        Duration::from_secs(60),
    )
    .await
    {
        Ok(o) => record(
            "环境变量、工作目录、用户、HOME、工具",
            format!("「{}」{}", one_line(&o.stdout), o.exit),
        ),
        Err(e) => record("环境变量、工作目录、用户、HOME、工具", format!("失败：{e}")),
    }

    // 长时间没输出：流会不会被中间的网关断掉。
    let quiet: u64 = env("ACS_QUIET_SECS")
        .and_then(|v| v.parse().ok())
        .unwrap_or(90);
    if quiet > 0 {
        let t = Instant::now();
        let cmd = format!("sleep {quiet}; echo late");
        match run(
            p,
            id,
            &["sh", "-c", &cmd],
            &[],
            None,
            Duration::from_secs(quiet + 60),
        )
        .await
        {
            Ok(o) if o.stdout == "late" => record(
                &format!("{quiet} 秒没输出"),
                format!("没断（{:.0} 秒，{}）", t.elapsed().as_secs_f32(), o.exit),
            ),
            Ok(o) => record(
                &format!("{quiet} 秒没输出"),
                format!(
                    "输出不对「{}」{}（{:.0} 秒）",
                    one_line(&o.stdout),
                    o.exit,
                    t.elapsed().as_secs_f32()
                ),
            ),
            Err(e) => record(&format!("{quiet} 秒没输出"), format!("失败：{e}")),
        }
    }

    // 从沙箱里连模型网关的端口：服务机上的监听看到的来源地址应该是沙箱的 Pod IP。
    if let Some(gateway) = env("ACS_GATEWAY") {
        let script = format!(
            "import urllib.request,sys\ntry:\n    r = urllib.request.urlopen('http://{gateway}/probe-from-{id}', timeout=8)\n    print('http', r.status)\nexcept Exception as e:\n    print('err', getattr(e, 'code', None) or type(e).__name__, str(e)[:120])\n"
        );
        match run(
            p,
            id,
            &["python3", "-c", &script],
            &[],
            None,
            Duration::from_secs(30),
        )
        .await
        {
            Ok(o) => record(
                &format!("沙箱连 {gateway}"),
                format!(
                    "「{}」（沙箱地址 {}，对一下服务机上监听的日志）",
                    one_line(&o.stdout),
                    first_address.map_or("-".into(), |a| a.to_string())
                ),
            ),
            Err(e) => record(&format!("沙箱连 {gateway}"), format!("失败：{e}")),
        }
    }

    // 暂停、恢复：状态、地址变不变、文件还在不在、还能不能跑命令。
    let t = Instant::now();
    match p.pause(id).await {
        Ok(()) => {
            let paused = t.elapsed();
            let state = p.get(id).await;
            record(
                "暂停",
                format!(
                    "{:.1} 秒，之后查到的状态：{}",
                    paused.as_secs_f32(),
                    match &state {
                        Ok(Some(i)) => format!("{:?}，地址 {:?}", i.state, i.address),
                        Ok(None) => "查不到了".into(),
                        Err(e) => format!("出错 {e}"),
                    }
                ),
            );
            let t = Instant::now();
            match p.resume(id).await {
                Ok(info) => {
                    record(
                        "恢复",
                        format!(
                            "{:.1} 秒，状态 {:?}，地址 {:?}（{}）",
                            t.elapsed().as_secs_f32(),
                            info.state,
                            info.address,
                            if info.address == first_address {
                                "没变"
                            } else {
                                "变了"
                            }
                        ),
                    );
                    match p.read_file(id, "workspace/probe.txt", 1 << 20).await {
                        Ok(back) if back == token.as_bytes() => record("恢复后文件", "还在"),
                        Ok(_) => record("恢复后文件", "内容变了"),
                        Err(e) => record("恢复后文件", format!("读不到：{e}")),
                    }
                    match run(
                        p,
                        id,
                        &["sh", "-c", "echo again"],
                        &[],
                        None,
                        Duration::from_secs(60),
                    )
                    .await
                    {
                        Ok(o) => record(
                            "恢复后跑命令",
                            format!("「{}」{}", one_line(&o.stdout), o.exit),
                        ),
                        Err(e) => record("恢复后跑命令", format!("失败：{e}")),
                    }
                }
                Err(e) => record("恢复", format!("失败：{e}")),
            }
        }
        Err(e) => record("暂停", format!("失败：{e}")),
    }

    // 大文件：上传、下载的速度。
    let mb: usize = env("ACS_FILE_MB")
        .and_then(|v| v.parse().ok())
        .unwrap_or(16);
    if mb > 0 {
        let data: Vec<u8> = (0..mb * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        let t = Instant::now();
        match p.write_file(id, "workspace/big.bin", &data).await {
            Ok(()) => {
                let up = t.elapsed();
                let t = Instant::now();
                match p
                    .read_file(id, "workspace/big.bin", (data.len() + 1) as u64)
                    .await
                {
                    Ok(back) => record(
                        &format!("{mb} MB 的文件"),
                        format!(
                            "上传 {:.1} 秒，下载 {:.1} 秒，内容{}",
                            up.as_secs_f32(),
                            t.elapsed().as_secs_f32(),
                            if back == data { "一致" } else { "不一致" }
                        ),
                    ),
                    Err(e) => record(
                        &format!("{mb} MB 的文件"),
                        format!("上传 {:.1} 秒，下载失败：{e}", up.as_secs_f32()),
                    ),
                }
            }
            Err(e) => record(&format!("{mb} MB 的文件"), format!("上传失败：{e}")),
        }
    }

    // 空闲：超过创建时的 300 秒超时以后沙箱还在不在（never-timeout）。
    let idle: u64 = env("ACS_IDLE_SECS")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if idle > 0 {
        tokio::time::sleep(Duration::from_secs(idle)).await;
        match p.get(id).await {
            Ok(Some(info)) => {
                let alive = run(
                    p,
                    id,
                    &["sh", "-c", "echo alive"],
                    &[],
                    None,
                    Duration::from_secs(60),
                )
                .await;
                record(
                    &format!("空闲 {idle} 秒以后"),
                    format!(
                        "还在，状态 {:?}，跑命令：{}",
                        info.state,
                        match alive {
                            Ok(o) => format!("「{}」", one_line(&o.stdout)),
                            Err(e) => format!("失败 {e}"),
                        }
                    ),
                );
            }
            Ok(None) => record(
                &format!("空闲 {idle} 秒以后"),
                "没了（never-timeout 没起作用）",
            ),
            Err(e) => record(&format!("空闲 {idle} 秒以后"), format!("查不了：{e}")),
        }
    }
}

#[tokio::main]
async fn main() {
    let Some(api_url) = env("ACS_API_URL") else {
        eprintln!("要设 ACS_API_URL（和 ACS_API_KEY），见文件开头的说明");
        std::process::exit(2);
    };
    let template = env("ACS_TEMPLATE").unwrap_or_else(|| "code-interpreter".into());
    let cfg = AcsConfig {
        api_url,
        data_url: env("ACS_DATA_URL"),
        api_key: env("ACS_API_KEY"),
        root: env("ACS_ROOT").unwrap_or_else(|| "/sandbox".into()),
        ..AcsConfig::default()
    };
    println!("配置：{cfg:?}，模板 {template}");
    let p = match AcsProvider::new(cfg) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("建不了 AcsProvider：{e}");
            std::process::exit(1);
        }
    };

    let t = Instant::now();
    let spec = CreateSpec {
        template: template.clone(),
        metadata: BTreeMap::from([("purpose".to_owned(), "thinktin-probe".to_owned())]),
        ..CreateSpec::default()
    };
    let info = match p.create(spec).await {
        Ok(info) => info,
        Err(e) => {
            record("建沙箱", format!("失败：{e}"));
            std::process::exit(1);
        }
    };
    let id = info.id.clone();
    record(
        "建沙箱",
        format!(
            "{:.1} 秒，{}，状态 {:?}，地址 {:?}，元数据 {:?}",
            t.elapsed().as_secs_f32(),
            id,
            info.state,
            info.address,
            info.metadata
        ),
    );
    match p.get(&id).await {
        Ok(Some(got)) => record(
            "查沙箱",
            format!(
                "状态 {:?}，地址 {:?}（{}）",
                got.state,
                got.address,
                if got.address == info.address {
                    "和创建时一样"
                } else {
                    "和创建时不一样"
                }
            ),
        ),
        Ok(None) => record("查沙箱", "查不到刚建的沙箱"),
        Err(e) => record("查沙箱", format!("失败：{e}")),
    }
    if info.state == SandboxState::Running {
        probe(&p, &id, info.address).await;
    }

    let t = Instant::now();
    match p.destroy(&id).await {
        Ok(()) => {
            let after = p.get(&id).await;
            record(
                "删除",
                format!(
                    "{:.1} 秒，之后查：{}",
                    t.elapsed().as_secs_f32(),
                    match after {
                        Ok(None) => "没了".to_owned(),
                        Ok(Some(i)) => format!("还查得到，状态 {:?}", i.state),
                        Err(e) => format!("出错 {e}"),
                    }
                ),
            );
        }
        Err(e) => record(
            "删除",
            format!("失败：{e}（沙箱 {id} 可能还在，用 kubectl 删）"),
        ),
    }
}
