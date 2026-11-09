# 本机固定签名

此汉化分支的安装流程使用固定本地证书，不能回退到 ad-hoc 临时签名。

- 私钥仅保存在本机登录钥匙串，导入时设为不可导出；禁止上传私钥、PKCS#12 或钥匙串文件。
- 本机证书指纹读取自 `~/Library/Application Support/ThawSigning/identity.txt`，不进入 Git。
- 签名现成构建：`./scripts/sign-local.sh /path/to/Thaw.app`。
- `devrun.sh` 在安装前调用此脚本；证书缺失或不可信会停止安装。
- 为当前 Thaw 发布更新时，保持 `com.stonerl.Thaw` 和 `/Applications/Thaw.app`；`devrun.sh` 的 Debug 应用使用独立标识，权限也独立。
- 不重新创建证书，不修改签名要求以绕过校验，不自动重置 TCC 权限。
- 初次切换到固定证书可能需要重新授权。稳定签名可帮助系统识别后续版本，但不能保证系统升级或策略变化后绝不重新提示。
- 此证书是本地自签名证书，不是 Apple Developer ID，也不代表通过 Apple 公证。GitHub 仅发布签名应用与源码。
