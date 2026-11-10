-- 项目看板（0062）上只按项目（或项目和作者）找的：0062 里打头是 project_id 的索引都是部分索引，只带 project_id 的查询用不上。
-- 删项目后的分批清理和“还剩没有”（store project_lifecycle.rs）、删项目和成员行时两个外键的级联删除都要靠它，不然每次都扫全表。
-- 表是 8.17 新加的、还没发布过，所以普通的 CREATE INDEX 就行。
CREATE INDEX project_board_posts_member ON project_board_posts (project_id, author_user_id);
