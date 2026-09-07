# LightOffice 开发者指南 (Developer Guide)

LightOffice 是 ONLYOFFICE Desktop Editors 的内网定制版。本仓库**不 fork 上游源码**，
而是维护一层可幂等应用的 overlay：所有定制都通过 `scripts/apply_overlay.sh`
打进上游检出目录，每处改动都带 `LIGHTOFFICE-OVERLAY` 标记，
因此跟进上游新版本时只需重新 clone + 重放 overlay。

## 1. 仓库结构

```
lightoffice/
├── code_index.json          # 所有定制点的路径索引（由脚本生成并校验存在性）
├── overlay/                 # 注入上游树的文件
│   ├── web-apps/…/themes/theme_lightwps.json
│   ├── branding/            # splash / 图标 / About logo
│   ├── desktop-apps/…/version_p.h        # 二进制品牌字符串
│   ├── desktop-apps/…/providers/lightoffice/   # 内网云提供方
│   └── build/lightoffice_size_opt.{pri,cmake}  # 体积优化编译配置
├── scripts/                 # bootstrap / overlay / 优化 / 校验
├── deploy/                  # 内网 Nextcloud + Document Server 编排
├── tests/                   # 冒烟与协同测试
└── docs/
```

## 2. 上游架构与我们的切入点

上游桌面端是一个 Qt 外壳：它用 CEF 承载 `web-apps` 的 HTML/JS 编辑器界面，
文档模型与渲染在 `sdkjs` + `core` 中完成。下图中的 `C*` 类均来自
`desktop-apps/win-linux/src/`，可用 `grep -r "class CXxx" desktop-apps/win-linux/src`
逐一核对。

```mermaid
flowchart TB
    subgraph Shell["Qt 外壳 — desktop-apps/win-linux/src"]
        CMyApplicationManager["CMyApplicationManager<br/>进程入口"]
        CAscApplicationManagerWrapper["CAscApplicationManagerWrapper<br/>应用管理 / SDK 桥"]
        CMainWindow["CMainWindow<br/>主窗口"]
        CEditorWindow["CEditorWindow<br/>独立编辑器窗口"]
        CAscTabWidget["CAscTabWidget<br/>文档标签页"]
        CSplash["CSplash<br/>启动画面 ← 品牌定制"]
        CThemes["CThemes / CTheme<br/>主题管理 ← 主题定制"]
        CProviders["CProviders<br/>云提供方 ← 内网存储定制"]
        CUpdateManager["CUpdateManager<br/>更新检查"]
        CLogger["CLogger<br/>日志"]
    end

    subgraph Bridge["CEF 事件桥"]
        CCefEventsGate["CCefEventsGate<br/>原生 ← JS 事件"]
        CCefEventsTransformer["CCefEventsTransformer<br/>事件转换"]
    end

    subgraph Web["web-apps (HTML/JS 编辑器界面)"]
        Toolbar["Toolbar.js<br/>工具栏 ← 菜单裁剪"]
        Plugins["Plugins.js<br/>插件宿主 ← 已禁用(含 AI 助手)"]
        LayoutManager["LayoutManager.js<br/>元素可见性"]
    end

    subgraph Core["sdkjs + core (文档模型/渲染/转换)"]
        skin["skin.js<br/>画布配色"]
        coreconv["core 转换引擎"]
    end

    CMyApplicationManager --> CAscApplicationManagerWrapper
    CAscApplicationManagerWrapper --> CMainWindow
    CAscApplicationManagerWrapper --> CProviders
    CAscApplicationManagerWrapper --> CUpdateManager
    CMainWindow --> CAscTabWidget
    CMainWindow --> CSplash
    CMainWindow --> CThemes
    CAscTabWidget --> CEditorWindow
    CEditorWindow --> CCefEventsGate
    CCefEventsGate --> CCefEventsTransformer
    CCefEventsTransformer --> Toolbar
    CCefEventsTransformer --> Plugins
    Toolbar --> LayoutManager
    CThemes --> skin
    Toolbar --> coreconv
    CAscApplicationManagerWrapper --> CLogger
```

### 定制点速查

| 需求 | 文件 | 机制 |
|---|---|---|
| 配色主题 | `web-apps/…/themes/theme_lightwps.json` | 覆盖 `colors-table.less` 中的 `:root` CSS 变量；`canvas-*` 由 `sdkjs/common/skin.js` 直接消费 |
| 菜单裁剪 | 四个编辑器的 `app/controller/Toolbar.js` | 将协作页签 `setVisible('review', false)` |
| 移除 AI 助手 | `web-apps/…/lib/controller/Plugins.js` | AI 助手是插件而非内置 UI，禁用插件宿主即可移除 |
| 二进制品牌 | `desktop-apps/win-linux/src/prop/version_p.h` | 上游自带的 vendor 覆盖钩子（原用于 `__NCT` 构建） |
| 启动画面/图标 | `desktop-apps/win-linux/res/` | 由 `scripts/gen_branding.py` 生成，可复现 |
| 内网云 | `desktop-apps/common/loginpage/providers/lightoffice/` | 新增 provider + `lightoffice-cloud.js` 默认地址 |
| 体积优化 | `desktop-apps/win-linux/defaults.pri` | include 体积优化 `.pri`（`-Os` / `--gc-sections` / `-Wl,-s`） |

## 3. 构建系统的重要事实

**上游使用 qmake，不是 CMake。** 整棵树有 137 个 `.pro`、57 个 `.pri`，
而 `CMakeLists.txt` 只有 32 个（其中 27 个属于 `desktop-sdk`）。
因此体积优化配置的主入口是 `lightoffice_size_opt.pri`；
`lightoffice_size_opt.cmake` 仅用于 `desktop-sdk` 那部分 CMake 目标。

官方构建入口是独立仓库 `ONLYOFFICE/build_tools`（不是 DesktopEditors 的子模块）：

```bash
git clone --depth 1 https://github.com/ONLYOFFICE/build_tools.git
cd build_tools/tools/linux && ./automate.py desktop
```

`automate.py` 会依次：自举一个私有 python3 → apt 安装约 40 个依赖 →
拉取预编译 Qt 5.9.9 → 拉取 ubuntu16 sysroot → 编译 core/sdkjs/desktop。

## 4. 本地开发流程

```bash
scripts/bootstrap.sh              # clone 上游 + 子模块
scripts/apply_overlay.sh          # 打入定制
scripts/apply_build_flags.sh      # 打入体积优化编译配置
scripts/trim_dictionaries.sh      # 裁剪词典
scripts/optimize_assets.sh        # 压缩静态资源（--lossy 可选）
scripts/verify_ac.sh              # 逐条核对验收标准
```

查看 overlay 到底改了什么：

```bash
git -C /home/user/onlyoffice-src submodule foreach 'git diff --stat'
```

回滚某个子模块的全部定制：

```bash
git -C /home/user/onlyoffice-src/web-apps checkout -- .
```

## 5. 跟进上游版本

1. 重新 clone 上游到干净目录（或 `git submodule update --remote`）。
2. 运行 `scripts/apply_overlay.sh`；若某处 anchor 失配，脚本会打印
   `anchor-not-found` 而不是静默跳过 —— 这就是需要人工适配的信号。
3. Toolbar 补丁会把上游原表达式抄进注释，diff 中可直接看到上游是否改了判断条件。
4. `python3 scripts/gen_code_index.py` 重新生成索引；任何路径失效都会非零退出。

## 6. 代码风格

overlay 里的补丁遵循上游文件既有风格（缩进、注释密度、命名），
补丁注释只解释「为什么」，不复述代码在做什么。
