# 界面字体

按 [DESIGN.md](../../DESIGN.md) 打包的本地字体，桌面直接使用此目录，Android 的 `assets/fonts` 保留相同文件用于独立打包；两端都不在运行时请求外部字体服务。Android 与电脑嵌入式预览改为共用 Noto Sans SC，电脑 React 外壳仍使用系统字体。

- Archivo Black：`ArchivoBlack-Regular.ttf`；[Google Fonts 来源](https://github.com/google/fonts/tree/main/ofl/archivoblack)；[OFL 许可](ArchivoBlack-OFL.txt)；SHA-256 `dd9a89a019b4849f66ab75455fe7bdf931311042cbb0f0f97acc061539703180`。
- Work Sans：`WorkSans.ttf`；[Google Fonts 来源](https://github.com/google/fonts/tree/main/ofl/worksans)；[OFL 许可](WorkSans-OFL.txt)；SHA-256 `f50f61f2ba738e239442d40bf1069adb195c224b6a5a73a581fc2f3ed62a9f63`。
- Space Mono：`SpaceMono-Regular.ttf`；[Google Fonts 来源](https://github.com/google/fonts/tree/main/ofl/spacemono)；[OFL 许可](SpaceMono-OFL.txt)；SHA-256 `95837e182baeeada83368f7748db28357f0a1b75c6b84ff7065b5edf933c8e18`。

- Noto Sans SC：打包于 `apps/android/assets/fonts/NotoSansSC.ttf`；[Google Fonts 来源](https://github.com/google/fonts/tree/main/ofl/notosanssc)；[OFL 许可](../../apps/android/assets/fonts/NotoSansSC-OFL.txt)。用于 Android 与电脑预览的中文和拉丁文字，构建时复制到本地 Web 资源。
