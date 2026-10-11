# Manual UI checks (v1.2)

`ic-lab ui-smoke` covers what can be automated (criteria U1-U7 in
[RELEASE_CRITERIA_v1.2.md](RELEASE_CRITERIA_v1.2.md)): the window appears, the Dock icon
comes and goes with it, reopening brings it back, a login launch shows no window, the icon
resource is present, quit works. The steps below need a person. Record the date, the macOS
version and the result of each step in an issue or in [COMPATIBILITY.md](COMPATIBILITY.md).

1. **Finder and Applications.** Open `~/Applications` (or `/Applications`) in Finder: the
   iClear icon (blue-teal tile, gauge arc, two pause bars) shows, not the generic app icon.
2. **Launchpad and Spotlight.** Search "iClear" in Spotlight and open Launchpad: the same
   icon; opening it from either shows the "iClear" window.
3. **Dock.** While the window is open the Dock shows the iClear icon; closing the window
   removes it (unless Settings > Keep in Dock is on); clicking the Dock icon or opening the
   app again from Finder brings the window back.
4. **Menu bar.** The menu-bar item keeps working with the window closed; its popover shows
   the same content as the window.
5. **Open at login.** Turn on Settings > Open at login, log out and back in: iClear is in
   the menu bar with no window; System Settings > General > Login Items lists it. Turn it
   off again: it disappears from that list.
6. **Onboarding.** On first launch (or with `defaults delete io.github.urrra39.iclear
   onboardingDone`), the window shows three cards: what iClear does; Observe mode; the
   switches and the optional Accessibility permission. Next, Back and Got it work; the
   Accessibility button opens the right System Settings pane.
7. **VoiceOver.** With VoiceOver on (Command-F5), every button in the window and the
   popover reads a meaningful label (Resume all, Pause, Pop, the per-app Resume and Never
   buttons), and the menu-bar item reads the health score.
8. **Uzbek.** With the system language set to Uzbek (or `-AppleLanguages "(uz)"`), every
   string in the window, the popover and the onboarding cards is in Uzbek.
9. **Emergency.** With apps paused, Resume all in the window and Control-Option-Command-T
   (while the app runs) resume them; closing the window does not change that.
