# Transpoon

Transpoon is a Hammerspoon module that allows you to obtain quick translations for the last phrase spoken by VoiceOver or the contents of the clipboard. It can also automatically translate any spoken phrase in realtime. 

## Installation

First, download and install Hammerspoon. You can do so either [from their Github](https://github.com/Hammerspoon/hammerspoon/releases/latest), or if you have it installed, through homebrew simply by running "brew install Hammerspoon" in the terminal. Once you have it installed, run it, and follow the prompts to grant accessibility permissions (I also choose to hide the app from the dock here so it stays out of your command-tab switcher)

You also need to allow external apps to control VoiceOver through Apple Script. To do so, open VoiceOver utility with VO + f8, navigate to the "General" section and check the "Allow VoiceOver to be controlled with AppleScript" checkbox.

Once Hammerspoon is installed and configured, navigate into the folder where you cloned this repository with Finder or another file manager, and open "Transpoon.spoon" which should cause Hammerspoon to install it into the right place. Finally, from the Hammerspoon menu extra select the open configuration option which should open your default text editor with your init.lua file. To make SpeechHistory work and do its thing, simply add the following 2 lines:
```lua
hs.loadSpoon("Transpoon")
spoon.Transpoon:start()
```

Save the file, return to the Hammerspoon menu extra but this time click the reload configuration option for your new changes to take effect. Mac OS will warn you that Hammerspoon is trying to control Voice Over. Grant it permission and the spoon should start working.


## Hotkeys

| Command | Description |
| --- | --- |
| Control+Shift+T | Translate last spoken phrase |
| Control+Shift+Y | Translate Clipboard |
| Control+Shift+A | Start and stop realtime auto translation |
| Control+Shift+D | Set destination language or open reference |

There's no special hotkey to copy the translation result, Vo + Shift + c is enough.

## Credits

Overal code structure and installation instructions taken from [Indent Beeper](https://github.com/pitermach/IndentBeeper) and [Speech History](https://github.com/mikolysz/speech-history)