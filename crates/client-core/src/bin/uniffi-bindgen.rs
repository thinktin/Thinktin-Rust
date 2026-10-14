//! 生成 Swift / Kotlin 绑定：`cargo run -p client-core --features bindgen --bin uniffi-bindgen -- generate ...`
//! （见 `tools/client-core/`）。

fn main() {
    uniffi::uniffi_bindgen_main()
}
