# 分支工作流

本仓库使用两个长期分支：

| 分支 | 用途 | 跟踪 | 推送目标 |
| --- | --- | --- | --- |
| `main` | 源仓库（`Kepler16f/HGhub`）镜像，只做同步 | `upstream/main` | `origin/main` |
| `myguo` | 本地开发、构建和发版 | `origin/myguo` | `origin/myguo` |

## 日常开发

```bash
git checkout myguo
# 修改、构建、测试
git add -A
git commit -m "..."
git push origin myguo
```

本地构建/安装：

```bash
pnpm ios:install -- --release
pnpm macos:release
```

## 定期同步源仓库

推荐用脚本：

```bash
# 只更新本地 main 和 myguo
pnpm sync:upstream

# 同时推送 origin/main 和 origin/myguo
pnpm sync:upstream -- --push
```

脚本做的事：

1. `git fetch upstream --tags`
2. `git checkout main && git merge --ff-only upstream/main`
3. `git checkout myguo && git merge main`
4. 有冲突时停下，解决后手动提交

手动等价命令：

```bash
git fetch upstream --tags
git checkout main
git merge --ff-only upstream/main
git push origin main
git checkout myguo
git merge main
git push origin myguo
```

注意：`main` 只接受 fast-forward。如果 `main` 上出现了本地提交，先确认是否需要，否则同步会失败。

## 发版

发版必须从 `myguo` 分支打 tag，不要从 `main` 打：

```bash
git checkout myguo
git pull origin myguo

# iOS
git tag v1.2.3-ios
git push origin v1.2.3-ios

# 桌面端 / Android
git tag v1.2.3
git push origin v1.2.3
```

GitHub Actions 会根据 tag 构建并发布对应 Release。

## 应用内更新

合并上游 v1.2.2 后，updater 与旧版更新检查已指向 `azazil/HGhub`：

- `src-tauri/tauri.conf.json` 的 `plugins.updater.endpoints`
- `src-tauri/src/api.rs` 的 `REPO`

要让应用内更新可用，需要：

1. `pnpm tauri signer generate` 生成自己的密钥对
2. 把公钥填到 `plugins.updater.pubkey`
3. 在 GitHub 仓库 Secrets 配置 `TAURI_SIGNING_PRIVATE_KEY` 和 `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`

在配置完成前，更新检查可能返回错误，但不会影响正常使用和发版。
