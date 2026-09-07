# LightOffice

基于 [ONLYOFFICE Desktop Editors](https://github.com/ONLYOFFICE/DesktopEditors)
的内网轻量版办公套件。

本仓库**不 fork 上游源码**。它维护一层可幂等应用的 overlay —— 主题、品牌、
菜单裁剪、内网云配置、体积优化编译参数 —— 由脚本打进上游检出目录。
每处改动都带 `LIGHTOFFICE-OVERLAY` 标记，因此跟进上游新版本时
只需重新 clone 再重放 overlay，而不是维护一棵长期分叉的树。

## 快速开始

```bash
scripts/bootstrap.sh              # clone 上游 DesktopEditors + build_tools
scripts/fetch_prebuilts.sh        # 经 git 通道取得引导 python3 与 CEF，并链接系统 Qt
scripts/apply_overlay.sh          # 主题 / 品牌 / 菜单裁剪 / 内网云
scripts/apply_build_flags.sh      # -Os / --gc-sections / strip
scripts/trim_dictionaries.sh      # 词典裁剪 (239M -> 15M)
scripts/optimize_assets.sh        # 静态资源压缩 (--lossy 可选)
scripts/build_desktop.sh --check-only   # 先确认依赖齐备，再去掉该参数正式构建
scripts/package.sh                # 产出安装包 + checksums
scripts/verify_ac.sh              # 逐条核对 25 项验收标准

# 内网协作栈与协同测试
docker compose -f deploy/docker-compose.nextcloud.yml up -d
node tests/fixture_server.js &            # 供 Document Server 取文档与回调
node tests/coedit_browser.js              # 两个真实编辑器会话并发协同 (AC 3.3/3.4)
scripts/test_filelock.sh                  # 并发写入 -> 423 Locked (AC 3.5)
```

## CI / CD

| 工作流 | 触发 | 作用 |
|---|---|---|
| `ci.yml` | push / PR | lint（shellcheck、`bash -n`、`node --check`、JSON/SVG/YAML、workflow 内嵌 shell）、单元测试、品牌资源可复现性、仅仓库内的验收判据 |
| `integration.yml` | push to main / 每日 / 手动 | 拉起内网协作栈，跑 AC 3.1/3.3/3.4/3.5（真实编辑器并发协同 + 423 文件锁），上传证据 |
| `release.yml` | tag `v*` / 手动 | **ubuntu + windows + macos 三平台矩阵**产出 `.deb` / `.exe` / `.dmg`，校验大小与 checksums，发布 GitHub Release |
| `deploy.yml` | PR（仅校验）/ 手动 | 校验编排与地址一致性；`mode=deploy` 时经 SSH 部署到目标主机，失败自动回滚 |

`release.yml` 是 **AC 5.1 的正解**：跨平台打包与宿主机绑定，`.exe` 需 Windows +
MSVC/Inno Setup，`.dmg` 需 macOS + Xcode/codesign，单机无法伪造——托管 runner
矩阵是受支持的产出方式。注意各 runner 上仍需能取到 v8，否则构建任务会在
preflight 处停下并把原因写进 job summary。

本地跑同一套检查：

```bash
scripts/lint.sh     # 与 CI lint 任务完全一致
npm test            # 31 项单元测试
scripts/verify_ac.sh
```

单元测试刻意覆盖**跨文件一致性**：内网地址同时写在 CloudFormation 参数、
compose 默认值、provider 配置、客户端默认值与部署文档**五处**，
只有测试能挡住它们各自漂移——客户端指向一个栈已不再监听的地址时，
现象看起来像网络故障而不是配置错误。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `code_index.json` | 所有定制点的路径索引，由 `gen_code_index.py` 生成并校验存在性 |
| `overlay/` | 注入上游树的文件（主题、品牌资源、`version_p.h`、内网云 provider、编译配置） |
| `scripts/` | bootstrap / overlay / 优化 / 打包 / 验收脚本 |
| `deploy/` | 内网协作栈编排 + `aws/` 下的 CloudFormation（固定私有地址主机） |
| `tests/` | CDP 冒烟测试、并发协同测试、冷启动/内存基准 |
| `docs/` | 用户指南、部署指南、开发者指南 |
| `baseline/` | 各项基线数据与 `verify_ac.sh` 的 JSON 报告 |

## 部署形态

| 场景 | 需要什么 |
|---|---|
| 单机离线办公 | **只要安装包**。桌面编辑器本身完全离线可用，无需任何服务端。 |
| 内网协同编辑 | 安装包 **+** 服务端（Nextcloud + Document Server + MariaDB）。合并算法在 Document Server，不在客户端。 |

服务端可用 `deploy/docker-compose.nextcloud.yml` 部署到任意主机，
或用 `deploy/aws/lightoffice-stack.yaml` 在 AWS 上建一台固定私有地址的主机。

**关键约束**：客户端的默认门户地址是**编译期烘焙**的，不是安装时配置的。
因此服务端地址必须在**构建客户端之前**确定；CloudFormation 用
`PrivateIpAddress` 把实例钉死在该地址上，`npm test` 会校验
CFN 参数、compose 默认值、provider 配置、客户端默认值、部署文档五处是否一致。

另一处易错点：容器网桥地址（`172.28.7.0/24`）**客户端永远不可达**，
客户端只能走主机发布的端口（`:8080` / `:8081`）。测试会专门拦截
「把网桥地址写进客户端配置」这类错误。

## 验收状态

`scripts/verify_ac.sh` 会输出每一项的判定并写出 `baseline/ac_report.json`。
当前在本构建环境中的结果：

| 判定 | 数量 | 含义 |
|---|---|---|
| PASS | 13 | 断言通过 |
| ADJUSTED | 3 | 判据字面前提与代码库不符，同时给出字面结果与等价判据 |
| BLOCKED | 9 | 本环境无法评估（原因见下） |
| FAIL | 0 | — |

### 三项 ADJUSTED

这些判据的字面断言在本代码库中**不可能成立**，因此同时报告字面结果与等价判据，
而不是悄悄放行：

- **AC 1.2**（`CMakeLists.txt > 50`）—— ONLYOFFICE 使用 **qmake**。属于 ONLYOFFICE
  自身的 `CMakeLists.txt` 只有 32 个（其中 27 个在 `desktop-sdk`），而 `.pro` 有 127 个。
  构建期会拉取 boost/ICU/OpenSSL/CEF 的源码树，使全树计数涨到 237——但那与
  「核心 C++ 模块是否完整」无关，所以判定按排除 `3dParty` 后的数字给出。
- **AC 2.2**（`grep "AI助手" == 0`）—— 该字符串在 `web-apps` 中**从未出现**，
  裁剪前后都是 0，因此不度量任何东西。AI 助手在上游是**插件**而非内置 UI，
  实质裁剪通过禁用插件宿主完成，并已隐藏 4/4 编辑器的协作页签。
- **AC 3.4**（日志出现 `CRDT` 或 `change set applied`）—— ONLYOFFICE 用的是
  **Operational Transformation**，不是 CRDT；`change set applied` 在 core/sdkjs
  中出现 0 次，`CRDT` 的命中全部是测试夹具里的 base64 片段。等价行为已实测通过：
  两个真实编辑器会话并发编辑同一文档，双方各自收到对方的 `saveChanges` 变更集，
  光标双向同步，且无 `onError`。

### 9 项 BLOCKED 的两个根因

1. **构建卡在 v8** —— `core/DesktopEditor/doctrenderer` 需要一个 JS 引擎；
   Linux 下唯一替代 `use_javascript_core` 只链接 Apple 框架与 Objective-C 源码，
   仅限 macOS/iOS。构建 v8 需要 `depot_tools` + `gclient`，其来源
   `chromium.googlesource.com` 与 CIPD 服务均被本会话出网策略拒绝。
   其余依赖**已全部解决**：boost、CEF、ICU、OpenSSL 均已成功构建；
   引导 python3 与 CEF 通过 git 通道取得（见 `scripts/fetch_prebuilts.sh`），
   Qt 改用系统 5.15.13（上游自带的 `use_system_qt.py` 路径）。
   影响 AC 1.3、1.4、2.4、4.3、4.4、4.5、5.2、5.3。
   诊断：`scripts/build_desktop.sh --check-only`
2. **跨平台打包需要各自宿主** —— `.exe` 需 Windows + MSVC/Inno Setup，
   `.dmg` 需 macOS + Xcode/codesign，在 Linux 容器中无法产出。影响 AC 5.1。

> 另注：AC 4.4/4.5 是**相对基线**的判据，需要两次构建（未优化基线 + 优化版）
> 才能比较，仅有一个产物无法评估。

## 与上游的差异

| 项目 | 变更 |
|---|---|
| 主题 | 新增 `轻量版WPS主题`（90 个颜色键，浅色，按文档类型着色） |
| 菜单 | 隐藏 4 个编辑器的协作页签；禁用插件宿主（连带移除 AI 助手） |
| 品牌 | 启动画面、窗口图标、About logo、二进制版权串全部替换 |
| 云存储 | 新增内网 provider，默认地址 `http://10.0.7.10:8080` |
| 词典 | 48 个语种裁剪至 1 个（上游无 zh_CN 词典） |
| 体积 | `-Os`、`--gc-sections`、链接期 strip |

## 许可

上游 ONLYOFFICE Desktop Editors 以 AGPL-3.0 授权，本仓库的 overlay 同样适用。
品牌覆盖只改变本次构建的厂商标识，不移除上游自身的版权声明。
