## 0.4.2+limousine.1
* **Limousine fork.** Patched `wait_exit_thread` in `src/flutter_pty_unix.c`
  to retry `waitpid` on `EINTR` and check its return value before reading
  `status`. Fixes a macOS-only bug where unrelated `Process.run`/`start`
  subprocess exits would deliver `SIGCHLD` to the thread, interrupt
  `waitpid`, and post a garbage exit code — causing live PTYs to appear
  terminated in the UI. Also frees the per-thread `WaitExitOptions` on exit.

## 0.4.2
* Fix Linux compile error, thanks [@mengyanshou].

## 0.4.1
* Fix compile warning, thanks [@mengyanshou].

## 0.4.0
* Update to Dart3

## 0.3.1
* Update deps

## 0.3.0

* Fixes ignored working directory parameter for Unix [#3], thanks [@devmil].
* Support setting Windows environmental variable and working directory.

## 0.2.0

* Add optional read acknowledge [#2], thanks [@devmil].

## 0.1.1

* Update README

## 0.1.0

* Windows support.
* Support getting exit code

## 0.0.7

* Work on Linux #1
* Work on Android

## 0.0.6

* Flutter >=2.12.0

## 0.0.5

* Fix README syntax

## 0.0.4

* Support resizing of the pty

## 0.0.3

* Support passing env vars
## 0.0.2

* Support passing arguments
## 0.0.1

* Initial release

[#2]: https://github.com/TerminalStudio/flutter_pty/pull/2
[#3]: https://github.com/TerminalStudio/flutter_pty/pull/3

[@devmil]: https://github.com/devmil
[@mengyanshou]: https://github.com/mengyanshou