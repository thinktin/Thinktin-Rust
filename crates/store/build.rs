fn main() {
    // 迁移文件是 sqlx::migrate! 在编译时嵌进来的：只加了 .sql 文件也要重新编译。
    println!("cargo:rerun-if-changed=migrations");
}
