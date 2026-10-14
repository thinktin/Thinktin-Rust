-- 升级、回滚（WBS 6.7）：用户换了模板版本后，下次唤醒时按新版本重建沙箱（工作区卷保留）。
ALTER TABLE instances ADD COLUMN rebuild_pending boolean NOT NULL DEFAULT false;
