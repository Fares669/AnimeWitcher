# DM-29 multipart diagnostic

exit_status=0

```text
Resolving dependencies...
Downloading packages...
  _fe_analyzer_shared 91.0.0 (107.0.0 available)
  analysis_server_plugin 0.3.3 (0.3.22 available)
  analyzer 8.4.0 (14.3.0 available)
  analyzer_buffer 0.1.11 (0.3.4 available)
  analyzer_plugin 0.13.10 (0.14.16 available)
  archive 4.0.9 (4.2.0 available)
  build 4.0.7 (4.0.11 available)
  build_config 1.3.2 (1.3.3 available)
  build_daemon 4.1.3 (retracted, 4.1.6 available)
  build_runner 2.15.1 (2.16.1 available)
  built_value 8.12.6 (8.13.0 available)
  cached_network_image 3.4.1 (4.0.0 available)
  cached_network_image_platform_interface 4.1.1 (5.0.0 available)
  cached_network_image_web 1.3.1 (2.0.0 available)
  cli_util 0.4.2 (0.6.0 available)
  clock 1.1.2 (1.1.3 available)
  code_assets 1.2.1 (2.0.0 available)
  code_builder 4.11.1 (4.12.0 available)
  connectivity_plus 6.1.5 (7.3.1 available)
  cross_file 0.3.5+4 (0.3.5+5 available)
  custom_lint_core 0.8.1 (0.8.2 available)
  custom_lint_visitor 1.0.0+8.4.0 (1.0.0+9.0.0 available)
  dart_style 3.1.3 (3.1.13 available)
  dbus 0.7.14 (0.7.15 available)
  dio 5.11.0 (5.11.1 available)
  dio_web_adapter 2.2.1 (2.2.2 available)
  dpad 2.0.2 (3.0.0 available)
  dynamic_color 1.8.1 (2.1.0 available)
  file_picker 12.0.0-beta.7 (12.2.0 available)
  flutter_riverpod 3.1.0 (3.4.3 available)
  flutter_secure_storage 10.3.1 (11.0.0 available)
  flutter_secure_storage_darwin 0.3.2 (0.4.1 available)
  flutter_secure_storage_linux 3.0.1 (3.0.2 available)
  flutter_secure_storage_platform_interface 2.0.2 (2.0.3 available)
  flutter_volume_controller 2.0.1 (2.0.2 available)
  glob 2.1.3 (2.2.0 available)
  go_router 17.3.0 (18.0.1 available)
  go_router_builder 4.4.0 (4.5.0 available)
  google_sign_in_android 7.2.16 (7.2.17 available)
  google_sign_in_ios 6.3.0 (6.3.3 available)
  hooks 2.0.2 (2.2.0 available)
  hooks_riverpod 3.1.0 (3.4.3 available)
  image 4.8.0 (4.9.2 available)
  io 1.0.5 (1.1.0 available)
  jni_flutter 1.0.2 (1.0.3 available)
  material_color_utilities 0.13.0 (0.13.1 available)
  mime 2.0.0 (2.1.0 available)
  mockito 5.6.4 (5.8.1 available)
  objective_c 9.5.0 (9.6.0 available)
  package_config 2.2.0 (3.0.0 available)
  permission_handler 13.0.0 (13.0.2 available)
  permission_handler_android 14.0.0 (14.1.0 available)
  permission_handler_apple 9.5.0 (9.6.1 available)
  permission_handler_platform_interface 4.4.0 (4.4.1 available)
  platform 3.1.6 (3.2.0 available)
  pool 1.5.2 (1.5.3 available)
  pub_semver 2.2.0 (2.2.1 available)
  pubspec_parse 1.5.0 (1.6.0 available)
  record_use 0.6.0 (1.1.1 available)
  riverpod 3.1.0 (3.4.3 available)
  riverpod_analyzer_utils 1.0.0-dev.8 (1.0.0-dev.12 available)
  riverpod_annotation 4.0.0 (4.0.7 available)
  riverpod_generator 4.0.0+1 (4.0.9 available)
  riverpod_lint 3.1.0 (3.1.9 available)
  shared_preferences_android 2.4.27 (2.4.28 available)
  shared_preferences_foundation 2.5.6 (2.5.7 available)
  shimmer 3.0.0 (4.0.0 available)
  source_gen 4.2.4 (4.3.0 available)
  source_helper 1.3.8 (1.3.13 available)
  source_maps 0.10.13 (0.10.14 available)
  stack_trace 1.12.1 (1.12.2 available)
  stream_transform 2.1.1 (2.1.2 available)
  synchronized 3.4.1+1 (3.4.1+2 available)
  test 1.31.1 (1.32.0 available)
  test_api 0.7.12 (0.7.14 available)
  test_core 0.6.18 (0.6.20 available)
  url_launcher_android 6.3.32 (6.3.33 available)
  url_launcher_ios 6.4.1 (6.4.2 available)
  url_launcher_linux 3.2.2 (3.2.3 available)
  url_launcher_macos 3.2.5 (3.2.6 available)
  url_launcher_windows 3.1.5 (3.1.6 available)
  vm_service 15.2.0 (15.3.0 available)
  wakelock_plus 1.7.0 (1.8.0 available)
  wakelock_plus_platform_interface 1.6.0 (1.7.0 available)
  win32 6.3.0 (6.4.0 available)
  xml 6.6.1 (7.0.1 available)
  yaml 3.1.3 (3.1.4 available)
Got dependencies!
87 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.

::group::✅ Passing tests
✅ five parts cover each byte once
✅ visible part bytes wake a parent when native callbacks are missing
✅ exact visible part is adopted when native completion callback is lost
✅ native iOS byte bridge advances parent before final part file exists
✅ native iOS completion bridge adopts the exact moved part
✅ repeated system pauses recover only the affected identity
✅ iOS user pause drains launched native range without destructive pause
✅ resume during iOS pause drain reuses the same native child identity
✅ failed child while parent is pause-draining releases slot without retry
✅ user pause cancels a pending automatic part recovery
✅ a pump enqueue exception recovers without pausing the logical parent
✅ completed parts ignore duplicate and late nonfinal callbacks
✅ pause requests every connection before waiting for callbacks
✅ pause after recreation does not pause children with no native owner
✅ restored live native children count against the global budget
✅ missing worker callbacks begin governed recovery without pausing parent
✅ complete temp part is recovered at canonical path without a request
✅ pause and process recreation retain a complete part and resume only four
✅ a permanent failed part pauses siblings without deleting completed bytes
✅ merges out-of-order completions in byte order before marking complete
✅ a truncated completed part never marks the episode complete
✅ legacy checkpoint keeps complete children instead of resuming them
✅ recovers a durable temp manifest left by process termination
✅ adopts an already assembled target after a crash without redownloading
✅ sixteen connections expand only after each batch is ready
✅ global budget never hands more than sixteen children to native IO
✅ 429 during slow start falls back to last healthy level and teaches host
::endgroup::

🎉 27 tests passed.
```
