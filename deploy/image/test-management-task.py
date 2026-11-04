import contextlib
import importlib.util
import io
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('management_task', Path(__file__).with_name('run-management-task.py'))
task = importlib.util.module_from_spec(spec)
spec.loader.exec_module(task)


class TaskExitTests(unittest.TestCase):
    def result(self, code, stdout):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return task.run_task(['check'], runner=lambda *a, **kw: SimpleNamespace(
                returncode=code, stdout=stdout, stderr=''))

    def test_wrapper_zero_without_python_success_is_failure(self):
        self.assertEqual(self.result(0, 'Done.\n'), 1)

    def test_marker_must_be_a_complete_line(self):
        self.assertEqual(self.result(0, 'print("SEAFILE_MANAGEMENT_TASK_OK")\n'), 1)

    def test_successful_python_outcome_is_success(self):
        self.assertEqual(self.result(0, 'SEAFILE_MANAGEMENT_TASK_OK\nDone.\n'), 0)

    def test_nonzero_wrapper_still_fails(self):
        self.assertEqual(self.result(1, 'SEAFILE_MANAGEMENT_TASK_OK\n'), 1)


if __name__ == '__main__':
    unittest.main()
