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
scripts/apply_overlay.sh          # 主题 / 品牌 / 菜单裁剪 / 内网云
scripts/apply_build_flags.sh      # -Os / --gc-sections / strip
scripts/trim_dictionaries.sh      # 词典裁剪 (239M -> 15M)
scripts/optimize_assets.sh        # 静态资源压缩 (--lossy 可选)
scripts/build_desktop.sh          # 调用上游 automate.py（先跑 --check-only）
scripts/package.sh                # 产出安装包 + checksums
scripts/verify_ac.sh              # 逐条核对 25 项验收标准
```

## 仓库结构

| 路径 | 内容 |
|---|---|
| `code_index.json` | 所有定制点的路径索引，由 `gen_code_index.py` 生成并校验存在性 |
| `overlay/` | 注入上游树的文件（主题、品牌资源、`version_p.h`、内网云 provider、编译配置） |
| `scripts/` | bootstrap / overlay / 优化 / 打包 / 验收脚本 |
| `deploy/` | 内网 Nextcloud + ONLYOFFICE Document Server 编排（`10.0.7.0/24`） |
| `tests/` | CDP 冒烟测试、并发协同测试、冷启动/内存基准 |
| `docs/` | 用户指南、部署指南、开发者指南 |
| `baseline/` | 各项基线数据与 `verify_ac.sh` 的 JSON 报告 |

## 验收状态

`scripts/verify_ac.sh` 会输出每一项的判定并写出 `baseline/ac_report.json`。
当前在本构建环境中的结果：

| 判定 | 数量 | 含义 |
|---|---|---|
| PASS | 10 | 断言通过 |
| ADJUSTED | 2 | 判据字面前提与代码库不符，同时给出字面结果与等价判据 |
| BLOCKED | 13 | 本环境无法评估（原因见下） |
| FAIL | 0 | — |

### 两项 ADJUSTED

- **AC 1.2**（`CMakeLists.txt > 50`）—— ONLYOFFICE 使用 **qmake** 构建。
  全树只有 32 个 `CMakeLists.txt`（其中 27 个属于 `desktop-sdk`），
  而 `.pro` 有 137 个、`.pri` 有 58 个。无论克隆是否完整，该判据都不可能成立。
  等价判据（qmake 工程文件数 + `core` 的 12,254 个 C/C++ 源文件）已通过。
- **AC 2.2**（`grep "AI助手" == 0`）—— 该字符串在 `web-apps` 中**从未出现**，
  裁剪前后都是 0，因此该判据不度量任何东西。AI 助手在上游是**插件**而非内置 UI，
  实质裁剪通过禁用插件宿主完成，并已隐藏 4/4 编辑器的协作页签。

### 13 项 BLOCKED 的三个根因

1. **无法执行上游构建** —— `automate.py` 的第一步就要下载
   `ONLYOFFICE-data/build_tools_data` 中的引导 python3 与预编译 Qt 5.9.9，
   这两个 raw URL 在本会话的出网策略下返回 **HTTP 403**；
   该仓库的 git LFS 对象也不在匿名读取通道提供（拿到的是 133 字节指针）。
   影响 AC 1.3、1.4、2.4、4.3、4.4、4.5、5.2、5.3。
   诊断：`scripts/build_desktop.sh --check-only`
2. **无法拉取容器镜像** —— Docker Hub 的 blob CDN
   `production.cloudfront.docker.com:443` 被出网策略拒绝（403）。
   编排文件本身已通过 `docker compose config` 校验。
   影响 AC 3.1、3.3、3.4、3.5。证据：`baseline/egress_denials.json`
3. **跨平台打包需要各自宿主** —— `.exe` 需 Windows + MSVC/Inno Setup，
   `.dmg` 需 macOS + Xcode/codesign，在 Linux 容器中无法产出。
   影响 AC 5.1。

上述每一项的测试与打包脚本都已写好并通过语法校验，
在具备条件的环境（可访问上游构建产物 + 可拉取镜像 + CI 三平台矩阵）中可直接执行。

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
