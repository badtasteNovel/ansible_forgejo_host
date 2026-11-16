# issue
1. cat /proc/sys/net/ipv4/ip_local_port_range 發現每次 wsl 開機與windows 拿到的port 範圍都不同，如果與 30000~32767 (cilium 互相撞到會讓cilium-agent 處於 CrashLoopBackOff 的問題)，而 wsl 在開機時就去跟 Windows 的 Hyper-V 網路橋接層「登記」一段範圍，後面維運去改 dynamic port 甚至會導致 wsl 無法上網，尚未有解決辦法
