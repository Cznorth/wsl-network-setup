Set sh = CreateObject("WScript.Shell")
' The hermes venv's Scripts\pythonw.exe is a console launcher (pops conhost);
' use the GUI-subsystem base pythonw. agent.py/supervisor.py are stdlib-only.
python = "C:\Users\cznorth\AppData\Roaming\uv\python\cpython-3.11.15-windows-x86_64-none\pythonw.exe"
agent = "D:\code\wsl-network-setup\tools\win-prototype\supervisor.py"
root = "C:\Users\cznorth\AppData\Local\SidekickDocker\win-proxy"
sh.Run Chr(34) & python & Chr(34) & " " & Chr(34) & agent & Chr(34) & " " & Chr(34) & root & Chr(34), 0, False
