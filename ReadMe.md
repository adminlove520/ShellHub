## 基于iptables+Nginx封禁异常访问的IP
### 脚本中各部分的详细解释
- 1.设置起始时间和结束时间： 脚本通过使用date命令设置了起始时间和结束时间，起始时间为5分钟前，结束时间为当前时间。
- 2.截取日志： 使用awk命令根据起始时间和结束时间从Nginx日志中截取出最近5分钟内的日志，并保存到临时文件tmp_last_minute.log中。
- 3.提取IP地址： 使用awk命令从临时文件中提取出所有的IP地址，并保存到另一个临时文件tmp_last_minute_ip.log中。
- 4.处理IP地址： 使用awk命令对IP地址进行处理，只保留前三位，并进行排序、去重和计数。然后根据设定的阈值（1500次），筛选出请求次数超过阈值的IP段，并将其保存到bad_ip_minute.list文件中。
- 5.封禁IP地址： 当存在需要封禁的IP段时，使用iptables命令逐个封禁IP地址。首先，使用grep命令根据IP段提取出具体的IP地址，然后使用iptables命令将这些IP地址添加到封禁列表中。
- 6.记录封禁的IP地址： 将被封禁的IP段记录到日志文件block_ip2.log中，包含封禁时间和被封禁的IP段。
- 7.解封IP地址： 使用iptables命令清空计数器，等待2分钟。然后，检查请求次数小于5次的IP段，并将其记录到good_ip2.list文件中，标记为白名单IP。最后，使用iptables命令逐个解封白名单IP。
- 8.记录解封的IP地址： 将被解封的IP地址记录到日志文件unblock_ip2.log中，包含解封时间和被解封的IP地址。
### 使用方法
- 1.脚本接受一个参数，即block或unblock，用于执行相应的功能。
- 2.通过运行脚本并传入合适的参数，可以实现IP封禁和解封的操作。
```
### cron定时任务
### 每5分钟执行一次block操作，每2小时执行一次unblock操作
*/5 * * * * root /data/nginx/log/Block_IP_WAF.sh block
0 */2 * * * root /data/nginx/log/Block_IP_WAF.sh unblock
```
## 一键批量创建用户并自动设置密码  
- 1.接收用户名列表：脚本接收任意数量的用户名作为参数（$@表示所有传递给脚本的参数），并遍历这个列表。

- 2.检查用户是否存在：使用id命令检查每个用户是否已经存在。如果用户不存在，则进入创建流程。

- 3.自动生成密码：脚本使用$RANDOM生成一个随机数，然后通过md5sum和cut命令生成一个8字符的密码。这种方法简单高效，适合快速生成安全密码。

- 4.创建用户并设置密码：useradd命令用于创建新用户，passwd --stdin用于将生成的密码设置给用户。所有这些操作都是静默完成的，不会显示任何输出或错误。

- 5.记录用户信息：脚本将新创建的用户名和对应的密码追加到一个名为user.info的文件中，方便后续查阅和管理。

- 6.输出创建结果：每个用户的创建结果都会被打印到屏幕上，便于管理员了解创建情况。
## 应急自动化分析脚本
### 作者：Anonymous
###  版本：v1.0
- 应急自动化分析脚本，采用python2.0,主要是通过ssh远程登录实现常见命令查看，所以在使用之前需要输入正确的服务器ip、ssh连接端口、ssh登录用户名、ssh登录密码，
主要实现如下功能:
- 1、获取系统基本信息，ip地址，主机名称，版本；
- 2、根据netstat、cpu占用率，获取异常程序pid，并定位异常所在路径；
- 3、常见系统命令可能会被恶意文件替换修改，识别常见系统命令是否被修改；
- 4、查看系统启动项目，根据时间排序，列出最近修改的前5个启动项
- 5、查看历史命令，列出处存在可疑参数的命令；
- 6、查看非系统用户；
- 7、查看当前登录用户（tty 本地登陆  pts 远程登录）；
- 8、通过查看passwd文件，确定系统当前用户
- 9、查看crontab定时任务
- 10、查看、保存最近三天系统文件修改情况
- 11、查看passwd，存在哪些用户id为0的特权用户
- 12、分析secure日志，判断其中是否存在异常ip地址
- 上述所有操作均输出保存在log文件中

## 日志管理脚本
### v1.0.1
- 定时清空日志文件内容：当时间为0点或12点时，脚本将自动清空目标目录下的所有文件内容，但不删除文件本身。这样可以确保日志文件始终保持较小的体积，避免占用过多的存储空间。

- 定时记录文件大小：在非清空时间，脚本将统计目标目录下各个文件的大小，并将结果输出到一个以时间和日期命名的日志文件中。这样你可以方便地查看各个日志文件的大小变化，及时发现异常增长或缩小的情况。
- 1、保存脚本：首先``` git clone https://git.nxwysoft.com/HopeSecurity/ShellHub.git ```

- 2、赋予执行权限：在终端中，使用chmod +x log_management.sh命令为脚本赋予执行权限。

- 3、设置定时任务：你可以使用crontab命令设置定时任务，让脚本每小时执行一次。例如，在终端中输入crontab -e命令编辑定时任务，并添加以下行：0 * * * * /path/to/log_management.sh。这表示每小时的第0分钟执行一次脚本。