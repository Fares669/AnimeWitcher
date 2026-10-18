"""Guard device-wide player wiring, including lifecycle and permission paths."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / 'lib/features/player/presentation'

class DeviceControlsContract(unittest.TestCase):
    def test_shared_volume_controller_uses_device_volume(self):
        text = (PLAYER / 'player_controller_base.dart').read_text()
        start = text.index('Future<double> getVolumeLevel()')
        self.assertIn('_platformService.getVolumeLevel()', text[start:])
        self.assertIn('_platformService.setVolumeLevel(', text[start:])
        self.assertNotIn('_getEngineVolumeLevel()', text[start:])

    def test_brightness_gesture_writes_system_not_application(self):
        text = (PLAYER / 'player_gesture_handler.dart').read_text()
        self.assertIn('setSystemScreenBrightness(', text)
        self.assertNotIn('.setApplicationScreenBrightness(', text)
        self.assertIn('await ScreenBrightness().system', text)

    def test_android_declares_special_access(self):
        text = (ROOT / 'android/app/src/main/AndroidManifest.xml').read_text()
        self.assertIn('android.permission.WRITE_SETTINGS', text)

    def test_device_changes_are_observed_and_subscriptions_owned(self):
        text = (PLAYER / 'widgets/animewitcher_player_controls.dart').read_text()
        self.assertIn('FlutterVolumeController.addListener(', text)
        self.assertIn('category: AudioSessionCategory.playback', text)
        self.assertIn('onSystemScreenBrightnessChanged.listen(', text)
        self.assertIn('s.cancel()', text)

    def test_exiting_player_does_not_restore_old_brightness(self):
        for name in ['player_screen.dart', 'widgets/animewitcher_player_controls.dart']:
            text = (PLAYER / name).read_text()
            self.assertNotIn('resetApplicationScreenBrightness()', text)

if __name__ == '__main__':
    unittest.main()
