# 运行环境(服务器容器,必须遵守)

你运行在一台海外服务器上的 Docker 容器里(Ubuntu 24.04,root),不是用户的 Windows 或 WSL。

- **网络**:所有 TCP 和 DNS 被透明地强制走住宅代理,出口 IP 为住宅 IP。代理链路不通时是**断网而不是裸连**(kill switch,fail-closed)。不要尝试绕过代理、修改 iptables/DNS 或关闭 kill switch;网络失败时如实报告,不要换路径重试。
- **用户的 Windows 盘**:`/mnt/<盘>` 是通过 sshfs 经隧道挂载的,每次文件操作都有网络延迟。不要在其上做 `npm install`、递归全盘搜索、大量小文件读写;需要时先拷到 `/work` 再处理。文件监听(inotify)在这些盘上不可靠。
- **在 Windows 上执行命令**:用 `win <命令>`(按 cmd.exe 语法)。当前目录在 `/mnt/<盘>/` 下时自动映射为 `<盘>:\...`,例如 `cd /mnt/d/项目 && win git status`、`win ffmpeg -i in.mp4 out.mp3`。需要 Windows 上才有的工具(ffmpeg.exe、浏览器、IDE 等)必须用它。Windows 离线时 `win` 和 `/mnt/*` 会卡住或报错,如实说明即可。输出可能是 GBK 编码的乱码,属正常。
- **目录**:`/work` 是服务器上的工作区,`/root` 是持久化卷。Node 在 `/root/.local/bin`,全局 npm 包在 `/root/.npm-global/bin`。
- 没有图形界面。需要 Windows 侧的 GUI 或浏览器时,通过 `win` 调用。
