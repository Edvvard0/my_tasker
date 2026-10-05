"""Importing this module registers the built-in tools. Later stages import their modules here."""

from tasker.ai import tools_events, tools_tasks
from tasker.finance import tools as finance_tools
from tasker.sleep import tools as sleep_tools
from tasker.study import tools as study_tools
from tasker.work import tools as work_tools

__all__ = [
    "finance_tools",
    "sleep_tools",
    "study_tools",
    "tools_events",
    "tools_tasks",
    "work_tools",
]
