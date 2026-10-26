"""把 ThinktinUI、App target 的源文件接进桩模块包（Gen/ 目录，生成物不提交）。

ThinktinKit、ThinktinCoreAdapter、App 的 App/、Platform/、Intents/ 和小组件扩展用符号链接；ThinktinUI 和它的测试复制一份，
顺便把 #Preview 宏换成普通的 @ViewBuilder 函数（桩 SwiftUI 没有宏），这样预览里的代码也会被类型检查。
"""
import os, re, shutil, sys
# 仓库根目录按本文件的位置推出来：tools/apple/uicheck/prep.py
repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))
root = os.path.join(repo, "apps/apple/ThinktinKit")
gen = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Gen")
shutil.rmtree(gen, ignore_errors=True)
os.makedirs(gen)
os.symlink(os.path.join(root, "Sources/ThinktinKit"), os.path.join(gen, "ThinktinKit"))
os.symlink(os.path.join(root, "Sources/ThinktinCoreAdapter"), os.path.join(gen, "ThinktinCoreAdapter"))
app = os.path.join(root, "..")
os.makedirs(os.path.join(gen, "Thinktin"))
for d in ["App", "Platform", "Intents"]:
    os.symlink(os.path.join(app, "Thinktin", d), os.path.join(gen, "Thinktin", d))
# 小组件扩展（12.20、12.10）；App 和扩展共用的实时活动属性（Shared/）两边都接上，和 project.yml 一样。
os.makedirs(os.path.join(gen, "ThinktinWidgets"))
os.symlink(os.path.join(app, "ThinktinWidgets"), os.path.join(gen, "ThinktinWidgets", "Widgets"))
for target in ["Thinktin", "ThinktinWidgets"]:
    os.symlink(os.path.join(app, "Shared"), os.path.join(gen, target, "Shared"))
os.symlink(os.path.join(app, "Tests/ThinktinTests"), os.path.join(gen, "ThinktinTests"))
counter = [0]
def transform(text):
    def repl(m):
        counter[0] += 1
        return "@MainActor @ViewBuilder func __preview_%d() -> some View {" % counter[0]
    return re.sub(r'^#Preview(\(.*\))? \{$', repl, text, flags=re.M)
for src, dst in [("Sources/ThinktinUI", "ThinktinUI"), ("Tests/ThinktinUITests", "ThinktinUITests")]:
    for dirpath, _, files in os.walk(os.path.join(root, src)):
        for f in files:
            if not f.endswith(".swift"): continue
            rel = os.path.relpath(os.path.join(dirpath, f), os.path.join(root, src))
            out = os.path.join(gen, dst, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(os.path.join(dirpath, f)) as fh: text = fh.read()
            with open(out, "w") as fh: fh.write(transform(text))
print("previews transformed:", counter[0])
