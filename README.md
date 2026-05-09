# 一键安装脚本，简洁个人自用版

如果没有安装ocserv，脚本会直接安装。
如果已经安装ocserv，要先添加用户，才能正常使用。
配置证书是可选的，不配置也能用。配置了每次连接就不会再弹那个证书提示框。

## 预览

```
root@cn2:~# bash ocserv-simple.sh
请选择要执行的功能：
1) 添加 ocserv 用户   3) 配置证书           5) 关闭 ocserv        7) 更新脚本           9) 退出
2) 移除 ocserv 用户   4) 启动或重启 ocserv  6) 查看 ocserv 状态   8) 卸载 ocserv
#? 
```

## 系统要求

- 操作系统需要Ubuntu18.04及以上版本，CentOS7或者CentOS8及以上版本

## 安装方法

```
wget https://raw.githubusercontent.com/likelim/ocserv-simple/main/ocserv-simple.sh && bash ocserv-simple.sh
```

## 参考链接

- [Ocserv Official Website](http://www.infradead.org/ocserv/)
- [OpenConnect VPN Client](http://www.infradead.org/openconnect/)
- [CentOS](https://www.centos.org/)
- [Ubuntu](https://ubuntu.com/)
- [ocserv-install](https://github.com/wangwanjie/ocserv-install/)
