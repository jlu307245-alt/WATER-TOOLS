@echo off
chcp 65001 >nul
title 推送到 GitHub
cd /d "%~dp0"

echo ═══════════════════════════════════════════════
echo   推送到 GitHub  →  jlu307245-alt/WATER-TOOLS
echo ═══════════════════════════════════════════════
echo.

where git >nul 2>nul
if errorlevel 1 (
  echo [错误] 没找到 git，请先安装 Git for Windows
  pause & exit /b 1
)

echo [1/3] 检查远程地址...
git remote -v
echo.

echo [2/3] 开始推送...
echo     如弹出 GitHub 登录窗口，请点 [Sign in] 或 [Authorize]
echo     首次可能会要你输账号密码，用浏览器登录即可
echo.
git push -u origin master
set ERR=%errorlevel%
echo.

echo [3/3] 结果
if %ERR% neq 0 (
  echo.
  echo  ┌─────────────────────────────────────────────┐
  echo  │  ✗ 推送失败                                  │
  echo  │                                              │
  echo  │  常见原因：                                   │
  echo  │   1. 仓库名不对（去 GitHub 看地址栏）          │
  echo  │   2. 认证被取消（重跑一次，点 Authorize）      │
  echo  │   3. 网络问题（挂梯子再试）                    │
  echo  │                                              │
  echo  │  把上面的报错截图发我，我来判断                │
  echo  └─────────────────────────────────────────────┘
) else (
  echo.
  echo  ┌─────────────────────────────────────────────┐
  echo  │  ✓ 推送成功！                                │
  echo  │                                              │
  echo  │  下一步：                                     │
  echo  │   1. 打开 https://github.com/jlu307245-alt/  │
  echo  │             WATER-TOOLS/actions              │
  echo  │   2. 会看到编译正在跑（黄色圆点）              │
  echo  │   3. 等 3~6 分钟变绿                          │
  echo  │   4. 点进这次运行 → 页面底部 Artifacts         │
  echo  │   5. 下载 QzxyTamper-ipa → 解压得 .ipa        │
  echo  └─────────────────────────────────────────────┘
)

echo.
pause
