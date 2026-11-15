# 已停用的上游工作流

`release.yml` 与 `pricing-rules.yml` 来自原项目 nanvon/cc-bar，依赖原作者仓库的签名私钥与发布配置，在定制版仓库中无法运行，因此移出 `.github/workflows/` 停用。定制版通过本地 `scripts/build.sh` 构建并用 `gh release create` 手动发布。
