Capture Vision Transfer (Windows 便携包说明)
===========================================

1. 运行方式
- 双击 `run_app.bat` 启动程序。
- 程序主界面包含 `发送端` 和 `接收端` 两个页面。

2. 接收端 ffmpeg
- 便携包默认包含 `ffmpeg\bin\ffmpeg.exe`。
- 接收端会优先自动填入这个本地路径。
- 如果你使用自己的 ffmpeg，可在界面中改路径。

3. 采集卡设备名
- 可在接收端点击设备搜索按钮自动扫描。
- 若扫描失败，手动执行:
  ffmpeg -hide_banner -list_devices true -f dshow -i dummy
  从 `DirectShow video devices` 复制设备名填写。

4. 建议参数
- 发送端: 12 FPS, 重发系数 1 或 2。
- 接收端: 采集 1280x720@30, 解码 FPS 12。
- 如果丢帧明显，降低发送 FPS 或提高重发系数。

5. 输出文件
- 接收完成后会在输出目录写入时间戳前缀文件。
- 文件名非法字符会自动替换为 `_`。
