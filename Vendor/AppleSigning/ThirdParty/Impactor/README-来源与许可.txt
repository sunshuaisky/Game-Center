plumesign v2.7.3（Impactor 的命令行，第三方开源工具，作者 Samara M / claration，MIT 许可：LICENSE-Impactor-MIT.txt）的修改版，用于以你的 Apple ID 登录苹果开发者服务、签名并把 S2Arm 装到你的 iPhone；密码只交给它向 Apple 登录，S2Arm 不保存。
S2Arm 基于上游 v2.7.3 源码打上以下补丁后自行编译（随附补丁原文）：0001-anisette-v3-server.patch、0002-2fa-coherent-identity-no-loop.patch、0003-srp-password-protocol-s2k-fo.patch、0004-gui-log-file-and-login-outcome.patch、0005-provision-with-login-identity.patch
上游源码：https://github.com/claration/impactor/tree/v2.7.3
其中内嵌的 apple-codesign 0.29.0（未修改）以 MPL-2.0 发布（LICENSE-apple-codesign-MPL-2.0.txt），源码：
  https://github.com/claration/impactor/tree/v2.7.3/3rdparty/apple-codesign-0.29.0
