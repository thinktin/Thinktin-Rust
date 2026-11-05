//! 团队与团队模板（8.1）：8.13 起是单人项目（`projects.rs`）上的一层，接口和返回的结构不变。团队模板存在
//! `project_templates`（原来的 `teams`、`team_members`、`team_templates` 复制以后不再读写）。

use chrono::{DateTime, Utc};
use proto::domain::{
    ProjectId, Team, TeamId, TeamMember, TeamRole, TeamTemplate, TeamTemplateId, TeamTemplateSpec,
};
use uuid::Uuid;

use crate::projects::SoloAgent;
use crate::{Error, Result, Tenant, Tx, from_json, to_json};

fn solo(members: &[TeamMember]) -> Vec<SoloAgent> {
    members
        .iter()
        .map(|m| SoloAgent {
            instance_id: m.instance_id,
            is_lead: m.role == TeamRole::Lead,
            position: m.position,
        })
        .collect()
}

impl Tx<Tenant> {
    /// 建团队（单人项目）。成员必须是自己的、没删除的实例；最多一个负责人。
    pub async fn create_team(&mut self, name: &str, members: &[TeamMember]) -> Result<Team> {
        let id = self.create_solo_project(name, "", &solo(members)).await?;
        self.team(id.into()).await
    }

    pub async fn team(&mut self, id: TeamId) -> Result<Team> {
        let p = self.own_project(id.into()).await?;
        let members = self
            .my_project_agents(id.into())
            .await?
            .into_iter()
            .map(|a| TeamMember {
                instance_id: a.instance_id,
                role: if a.is_lead {
                    TeamRole::Lead
                } else {
                    TeamRole::Member
                },
                position: a.position,
            })
            .collect();
        Ok(Team {
            id,
            name: p.name,
            members,
            created_at: p.created_at,
        })
    }

    pub async fn teams(&mut self) -> Result<Vec<Team>> {
        let ids: Vec<ProjectId> = self
            .own_projects()
            .await?
            .into_iter()
            .map(|p| p.id)
            .collect();
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            out.push(self.team(id.into()).await?);
        }
        Ok(out)
    }

    /// 改名、整体替换成员（原地改：去掉的标成离开，留下的保留设置）。
    pub async fn update_team(
        &mut self,
        id: TeamId,
        name: Option<&str>,
        members: Option<&[TeamMember]>,
    ) -> Result<Team> {
        self.update_solo_project(id.into(), name).await?;
        if let Some(members) = members {
            self.replace_my_project_agents(id.into(), &solo(members))
                .await?;
        }
        self.team(id).await
    }

    pub async fn create_team_template(
        &mut self,
        name: &str,
        spec: &TeamTemplateSpec,
    ) -> Result<TeamTemplate> {
        let id = TeamTemplateId::new();
        let created_at: DateTime<Utc> = sqlx::query_scalar(
            "INSERT INTO project_templates (id, user_id, name, spec) VALUES ($1, app_user_id(), $2, $3) \
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
            "SELECT id, name, spec, created_at FROM project_templates ORDER BY created_at",
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
            sqlx::query_as("SELECT name, spec, created_at FROM project_templates WHERE id = $1")
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
        let done = sqlx::query("DELETE FROM project_templates WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}
