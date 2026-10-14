# Eggplant Boot 1.0.36

面向 Dopamine RootHide（ElleKit）的稳定修复版。沿用旧包 `com.attacker.eggplantboot`，版本从 `1.0.35` 升级为 `1.0.36`；最低 iOS 15，二进制包含 arm64 与 arm64e。加载过滤器仅匹配可执行文件 `Eggplant`。

稳定版只调整 App 来源调用读取到的开机日期，不全局修改 Mach 时钟、`systemUptime`、等待期限或 `syscall`。App 内直接执行 `SVC` 的读取不在此次覆盖范围内。构建检查通过只证明代码能够编译、打包和通过策略单元测试；红果 UI、播放和挂起恢复仍需真机测试。

## GitHub Actions 构建

在独立仓库 `pang5813/eggplant-boot-tweak` 的 Actions 中运行 **Build RootHide deb**。工作流使用 macOS 15 与原生 Xcode SDK，克隆官方 [RootHide Theos](https://github.com/roothide/theos)，固定提交 `cfba89a53a05b4a1b822121158acc3669c20602f`（2026-10-15 查询的 master HEAD），同时锁定该提交记录的子模块版本。

工作流先执行 `BootPolicy.c` 的原生单元测试，再打包和核对包 ID、版本、架构、文件路径与动态库依赖。构建成功后下载 **EggplantBoot-1.0.36-RootHide** artifact，里面包含 `.deb`、SHA-256、编译环境及 Mach-O 检查结果。

本包使用 `THEOS_PACKAGE_SCHEME=roothide`，deb 架构标记为 `iphoneos-arm64e`；沿用手机旧包的 `usr/lib/TweakInject/EggplantBootTweak.dylib` 与同名 plist，由 RootHide 安装到随机 bootstrap 根目录。不要手动加 `/var/jb` 前缀。详见 [RootHide 官方开发说明](https://github.com/roothide/Developer)。

## 本地 macOS 构建

先安装 Xcode，以及 Homebrew 的 `make ldid xz dpkg`，克隆上述提交的 RootHide Theos 并初始化递归子模块，将 `THEOS` 指向该目录，然后执行：

```sh
cc -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  BootPolicy.c tests/boot_policy_test.c -o /tmp/eggplant_boot_policy_test
/tmp/eggplant_boot_policy_test
gmake clean
gmake package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

输出位于 `packages/`。安装时作为同包 ID 的版本升级；完成后彻底退出红果再重新打开。
