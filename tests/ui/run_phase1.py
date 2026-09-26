"""Same DevEco Testing runner/config as the original smoke; isolated build required."""
import main  # Keep the established bundled hdc setup.

main.main_process('run -l PhoneOfflineAnnotation;PhoneSyncInteraction')
