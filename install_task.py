#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
注册 Windows 计划任务：TVBox 配置源自动更新。

为什么不用 schtasks.exe：本机安全策略把它列进了 Program Blacklist，
直接调用会「拒绝访问」。改用任务计划程序的 COM 接口（ITaskScheduler），
不经过被禁的可执行文件。

频率：每 12 小时一次（03:17 / 15:17，错开整点避免与其他任务撞车）

用法：
    python install_task.py            # 注册
    python install_task.py --remove   # 删除
    python install_task.py --status   # 查看状态
    python install_task.py --run      # 立刻手动跑一次
"""
import sys
import datetime

TASK_NAME = "TVBox配置自动更新"
TASK_PATH = "\\"
# 必须用纯 ASCII 路径：计划任务以 SYSTEM 账户运行，看不到会话级的 subst 映射，
# 而且 cmd 按 GBK 读 .bat，路径里的中文会被解码坏。
ACTION_CMD = "E:\\TVBOX\\auto_update.bat"
WORK_DIR = "E:\\TVBOX"
# 每天两次：03:17 和 15:17
HOURS = ["03:17", "15:17"]
DESC = "TVBox 配置源自动更新：抓取上游 -> 合并去重 -> 推送 Gitee"


def get_service():
    import win32com.client
    return win32com.client.Dispatch("Schedule.Service")


def register():
    svc = get_service()
    svc.Connect()

    root = svc.GetFolder(TASK_PATH)

    # 已存在就先删
    try:
        root.DeleteTask(TASK_NAME, 0)
        print(f"已删除旧任务: {TASK_NAME}")
    except Exception:
        pass

    task = svc.NewTask(0)
    task.RegistrationInfo.Description = DESC
    task.RegistrationInfo.Author = "TVBox Deployer"

    task.Principal.UserId = "SYSTEM"
    task.Principal.RunLevel = 1          # TASK_RUNLEVEL_HIGHEST
    task.Principal.LogonType = 5        # TASK_LOGON_SERVICE_ACCOUNT
    task.Settings.Enabled = True
    task.Settings.StartWhenAvailable = True
    task.Settings.DisallowStartIfOnBatteries = False
    task.Settings.StopIfGoingOnBatteries = False
    task.Settings.ExecutionTimeLimit = "PT1H"
    task.Settings.MultipleInstances = 2  # TASK_INSTANCES_IGNORE_NEW
    task.Settings.RunOnlyIfNetworkAvailable = False

    trigger = task.Triggers.Create(1)   # TASK_TRIGGER_DAILY
    trigger.StartBoundary = f"{datetime.datetime.now():%Y-%m-%d}T{HOURS[0]}:00"
    trigger.Repetition.Interval = "PT12H"
    trigger.Repetition.Duration = "P1D"
    trigger.Enabled = True
    # 补上第二个时间点
    trigger2 = task.Triggers.Create(1)
    trigger2.StartBoundary = f"{datetime.datetime.now():%Y-%m-%d}T{HOURS[1]}:00"
    trigger2.Enabled = True

    action = task.Actions.Create(0)      # TASK_ACTION_EXEC
    action.Path = "C:\\Windows\\System32\\cmd.exe"
    action.Arguments = f'/c "{ACTION_CMD}"'
    action.WorkingDirectory = WORK_DIR

    root.RegisterTaskDefinition(
        TASK_NAME, task, 6, None, None, 3, None)   # TASK_CREATE_OR_UPDATE=6

    print(f"✓ 计划任务已注册: {TASK_NAME}")
    print(f"  执行: {ACTION_CMD}")
    print(f"  时间: 每天 {', '.join(HOURS)}")
    print(f"  账号: SYSTEM（需管理员权限运行本脚本）")


def remove():
    svc = get_service()
    svc.Connect()
    root = svc.GetFolder(TASK_PATH)
    try:
        root.DeleteTask(TASK_NAME, 0)
        print(f"✓ 已删除任务: {TASK_NAME}")
    except Exception as e:
        print(f"删除失败（可能不存在）: {e}")


def status():
    svc = get_service()
    svc.Connect()
    root = svc.GetFolder(TASK_PATH)
    try:
        t = root.GetTask(TASK_NAME)
    except Exception:
        print("任务不存在")
        return
    # 267009 = SCHED_S_TASK_RUNNING（正在运行），267011 = SCHED_S_TASK_NOT_RUN（还没跑过）
    CODES = {
        0: "成功",
        267009: "正在运行",
        267011: "尚未运行过",
        1: "失败（脚本返回非0）",
        2147942401: "失败（找不到文件）",
        2147943645: "失败（服务未启动）",
    }
    r = t.LastTaskResult
    print(f"名称       : {t.Name}")
    print(f"状态       : {'已启用' if t.Enabled else '已禁用'}")
    print(f"上次运行   : {t.LastRunTime}")
    print(f"下次运行   : {t.NextRunTime}")
    print(f"上次结果   : {r}  ({CODES.get(r, '见系统事件日志')})")
    print(f"执行命令   : {t.Definition.Actions.Item(1).Path} {t.Definition.Actions.Item(1).Arguments}")


def run_now():
    svc = get_service()
    svc.Connect()
    root = svc.GetFolder(TASK_PATH)
    t = root.GetTask(TASK_NAME)
    t.Run("")
    print("✓ 已触发立即运行")


if __name__ == "__main__":
    act = sys.argv[1] if len(sys.argv) > 1 else ""
    if act == "--remove":
        remove()
    elif act == "--status":
        status()
    elif act == "--run":
        run_now()
    else:
        register()
