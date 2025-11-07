import threading
from typing import Callable, Any
from queue import Queue
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class TaskRunner:
    def __init__(self):
        self.current_task: threading.Thread | None = None
        self.cancelled = False
        self.result_queue: Queue = Queue()

    def run_with_progress(
        self,
        task_fn: Callable[[], Any],
        on_complete: Callable[[Any], None] | None = None,
        on_error: Callable[[Exception], None] | None = None,
    ) -> None:
        self.cancelled = False

        def task_wrapper():
            try:
                result = task_fn()
                if not self.cancelled:
                    self.result_queue.put(("success", result))
            except Exception as e:
                logger.error(f"Task failed: {e}", exc_info=True)
                if not self.cancelled:
                    self.result_queue.put(("error", e))

        self.current_task = threading.Thread(target=task_wrapper, daemon=True)
        self.current_task.start()

        def check_result():
            if not self.result_queue.empty():
                status, data = self.result_queue.get()
                if status == "success" and on_complete:
                    on_complete(data)
                elif status == "error" and on_error:
                    on_error(data)
                return False
            return True

        return check_result

    def cancel_task(self) -> None:
        self.cancelled = True
        logger.info("Task cancelled")

    def is_running(self) -> bool:
        return self.current_task is not None and self.current_task.is_alive()
