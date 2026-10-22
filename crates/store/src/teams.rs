//! 团队与团队模板（8.1）。

use chrono::{DateTime, Utc};
use proto::domain::{
    InstanceId, Team, TeamId, TeamMember, TeamRole, TeamTemplate, TeamTemplateId, TeamTemplateSpec,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, from_json, parse, to_json};

impl Tx<Tenant> {
    /// 建团队。成员必须是自己的、没删除的实例；最多一个负责人。
    pub async fn create_team(&mut self, name: &str, members: &[TeamMember]) -> Result<Team> {
        let id = TeamId::new();
        sqlx::query("INSERT INTO teams (id, user_id, name) VALUES ($1, app_user_id(), $2)")
            .bind(id.0)
            .bind(name)
            .execute(self.conn())
            .await?;
        self.insert_members(id, members).await?;
        self.team(id).await
    }

    async fn insert_members(&mut self, team: TeamId, members: &[TeamMember]) -> Result<()> {
        if members.iter().filter(|m| m.role == TeamRole::Lead).count() > 1 {
            return Err(Error::Invalid("a team has at most one lead".into()));
        }
        for m in members {
            self.instance(m.instance_id).await?;
            sqlx::query(
                "INSERT INTO team_members (team_id, instance_id, user_id, role, position) \
                 VALUES ($1, $2, app_user_id(), $3, $4)",
            )
            .bind(team.0)
            .bind(m.instance_id.0)
            .bind(m.role.as_str())
            .bind(i32::try_from(m.position).unwrap_or(i32::MAX))
            .execute(self.conn())
            .await?;
        }
        Ok(())
    }

    pub async fn team(&mut self, id: TeamId) -> Result<Team> {
        let (name, created_at): (String, DateTime<Utc>) =
            sqlx::query_as("SELECT name, created_at FROM teams WHERE id = $1")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        let rows: Vec<(Uuid, String, i32)> = sqlx::query_as(
            "SELECT m.instance_id, m.role, m.position FROM team_members m \
             JOIN instances i ON i.id = m.instance_id AND i.state <> 'deleted' \
             WHERE m.team_id = $1 ORDER BY m.position, m.instance_id",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?;
        let members = rows
            .into_iter()
            .map(|(instance, role, position)| {
                Ok(TeamMember {
                    instance_id: InstanceId(instance),
                    role: parse(&role)?,
                    position: u32::try_from(position).unwrap_or_default(),
                })
            })
            .collect::<Result<_>>()?;
        Ok(Team {
            id,
            name,
            members,
            created_at,
        })
    }

    pub async fn teams(&mut self) -> Result<Vec<Team>> {
        let ids: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM teams ORDER BY created_at")
            .fetch_all(self.conn())
            .await?;
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            out.push(self.team(TeamId(id)).await?);
        }
        Ok(out)
    }

    /// 改名、整体替换成员。
    pub async fn update_team(
        &mut self,
        id: TeamId,
        name: Option<&str>,
        members: Option<&[TeamMember]>,
    ) -> Result<Team> {
        let done = sqlx::query(
            "UPDATE teams SET name = coalesce($2, name), updated_at = now() WHERE id = $1",
        )
        .bind(id.0)
        .bind(name)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        if let Some(members) = members {
            sqlx::query("DELETE FROM team_members WHERE team_id = $1")
                .bind(id.0)
                .execute(self.conn())
                .await?;
            self.insert_members(id, members).await?;
        }
        self.team(id).await
    }

    pub async fn delete_team(&mut self, id: TeamId) -> Result<()> {
        let done = sqlx::query("DELETE FROM teams WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    pub async fn create_team_template(
        &mut self,
        name: &str,
        spec: &TeamTemplateSpec,
    ) -> Result<TeamTemplate> {
        let id = TeamTemplateId::new();
        let created_at: DateTime<Utc> = sqlx::query_scalar(
            "INSERT INTO team_templates (id, user_id, name, spec) VALUES ($1, app_user_id(), $2, $3) \
             RETURNING created_at",
        )
        .bind(id.0)
        .bind(name)
        .bind(to_json(spec)?)
        .fetch_one(self.conn())
        .await?;
        Ok(TeamTemplate {
            id,
            name: name.into(),
            spec: spec.clone(),
            created_at,
        })
    }

    pub async fn team_templates(&mut self) -> Result<Vec<TeamTemplate>> {
        let rows: Vec<(Uuid, String, serde_json::Value, DateTime<Utc>)> = sqlx::query_as(
            "SELECT id, name, spec, created_at FROM team_templates ORDER BY created_at",
        )
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|(id, name, spec, created_at)| {
                Ok(TeamTemplate {
                    id: TeamTemplateId(id),
                    name,
                    spec: from_json(spec, "team template")?,
                    created_at,
                })
            })
            .collect()
    }

    pub async fn team_template(&mut self, id: TeamTemplateId) -> Result<TeamTemplate> {
        let (name, spec, created_at): (String, serde_json::Value, DateTime<Utc>) =
            sqlx::query_as("SELECT name, spec, created_at FROM team_templates WHERE id = $1")
                .bind(id.0)
                .fetch_one(self.conn())
                .await?;
        Ok(TeamTemplate {
            id,
            name,
            spec: from_json(spec, "team template")?,
            created_at,
        })
    }

    pub async fn delete_team_template(&mut self, id: TeamTemplateId) -> Result<()> {
        let done = sqlx::query("DELETE FROM team_templates WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}
