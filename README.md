# tiny11builder
*Scripts to build a trimmed-down Windows 11 image - now in **PowerShell**!*

## Introduction :
Tiny11 builder, now completely overhauled. <br> After more than a year (for which I am so sorry) of no updates, tiny11 builder is now a much more complete and flexible solution - one script fits all. Also, it is a steppingstone for an even more fleshed-out solution.

You can now use it on ANY Windows 11 release (not just a specific build), as well as ANY language or architecture.
This is made possible thanks to the much-improved scripting capabilities of PowerShell, compared to the older Batch release.

This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
The script has also been updated to use DISM's recovery compression, resulting in a much smaller final ISO size, and no utilities from external sources. The only other executable included is **oscdimg.exe**, which is provided in the Windows ADK and it is used to create bootable ISO images. 
Also included is an unattended answer file, which is used to bypass the Microsoft Account on OOBE and to deploy the image with the `/compact` flag.
It's open-source, **so feel free to add or remove anything you want!** Feedback is also much appreciated.

Also included is a **core build mode** for a quick and dirty development testbed. Just the bare minimum, none
of the fluff. It generates a significantly reduced Windows 11 image. However, **it's not suitable for regular
use due to its lack of serviceability - you can't add languages, updates, or features post-creation**. The
core build is not a full Windows 11 substitute but a rapid testing or development tool, potentially useful
for VM environments.

---

## ⚠️ One script, two build modes:
- **Serviceable build** (default) : removes a lot of bloat but keeps the system serviceable. You can add
  languages, updates, and features post-creation. This is the recommended mode for regular use.
- ⚠️ **Core build** (`-Core` switch) : removes even more bloat but also removes the ability to service the
  image. You cannot add languages, updates, or features post-creation. Recommended for quick testing or
  development use, e.g. VMs.

There used to be a separate `tiny11coremaker.ps1` script for the core build. It has been folded into
`asl-win11maker.ps1` behind the `-Core` switch — there is now only one script.

## Instructions:
1. Download Windows 11 from the [Microsoft website](https://www.microsoft.com/software-download/windows11) or [Rufus](https://github.com/pbatard/rufus)
2. Mount the downloaded ISO image using Windows Explorer.
3. Open **PowerShell 5.1** as Administrator. 
5. Change the script execution policy :
```powershell
Set-ExecutionPolicy Bypass -Scope Process
```
> Using `-Scope Process` you keep your original policy intact as this change only lasts for the current PowerShell session. 

6. Start the script :
```powershell
.\asl-win11maker.ps1 -ISO <letter> -SCRATCH <letter>
```
For a core build, add `-Core`. To skip the interactive index prompt, pass `-INDEX <n>` (and `-ESDINDEX <n>`
if the source media ships an ESD). See `Get-Help .\asl-win11maker.ps1 -Full` for every parameter, including
the hardware-bypass strategy (`-BypassMode`) and driver injection (`-InjectSystemDrivers`, `-DriverPath`,
`-InjectVirtioDrivers`).

6. Select the drive letter where the image is mounted (only the letter, no colon (:)), if you didn't pass `-ISO`.
7. Select the SKU that you want the image to be based on, if you didn't pass `-INDEX`.
8. Sit back and relax :)
9. When the image is completed, you will see it in the `output\` folder, alongside a build-info JSON.

---

## What is removed:
<table>
  <tbody>
    <tr>
      <th>Serviceable build (default)</th>
      <th>Core build (<code>-Core</code>)</th>
    </tr>
    <tr>
      <td>
        <ul>
          <li>Clipchamp</li>
          <li>News</li>
          <li>Weather</li>
          <li>Xbox</li>
          <li>GetHelp</li>
          <li>GetStarted</li>
          <li>Office Hub</li>
          <li>Solitaire</li>
          <li>PeopleApp</li>
          <li>PowerAutomate</li>
          <li>ToDo</li>
          <li>Alarms</li>
          <li>Mail and Calendar</li>
          <li>Feedback Hub</li>
          <li>Maps</li>
          <li>Sound Recorder</li>
          <li>Your Phone</li>
          <li>Media Player</li>
          <li>QuickAssist</li>
          <li>Edge (files + uninstall entries, opt-in)</li>
          <li>OneDrive</li>
        </ul>
      </td>
      <td>
        <ul>
          <li>everything from the serviceable build, and forced on regardless of the opt-in comments, plus:</li>
          <li>Windows Component Store (WinSxS), stripped to an essential allowlist</li>
          <li>Windows Defender (services disabled, Settings pages hidden)</li>
          <li>Windows Update (aggressively disabled - wouldn't work without WinSxS anyway)</li>
          <li>WinRE</li>
          <li>Internet Explorer, WordPad, Tablet PC Math, Steps Recorder, and other system (CBS/FoD) components</li>
          <li>Edge WebView2's WinSxS assembly, in addition to the files removed by the serviceable build's Edge removal</li>
        </ul>
      </td>
    </tr>
  </tbody>
</table>

See `docs/tweak-catalog.md` for the complete, documented list of every app package prefix, scheduled task,
and registry tweak this repo applies (and the ones it ships commented-out or doesn't port at all).

Keep in mind that **you cannot add back features in the core build**! <br>
You will be asked during image creation if you want to enable .NET 3.5 support (or pass `-EnableDotNet35`
to skip the prompt).

---

## Known issues:
- Although Edge is removed, there are some remnants in the Settings, but the app in itself is deleted. 
- You might have to update Winget before being able to install any apps, using Microsoft Store.
- Outlook and Dev Home might reappear after some time. This is an ongoing battle, though the latest script update tries to prevent this more aggressively.
- If you are using this script on arm64, you might see a glimpse of an error while running the script. This is caused by the fact that the arm64 image doesn't have OneDriveSetup.exe included in the System32 folder.

---

## Features to be implemented:
- ~~disabling telemetry~~ (Implemented in the 04-29-24 release!)
- ~~more ad suppression~~ (Partially implemented in the 09-06-25 release!)
- ~~driver injection (host system + KVM/QEMU virtio)~~ (Implemented alongside the combined-builder release!)
- ~~selectable hardware-bypass strategy~~ (Implemented alongside the combined-builder release!)
- improved language and arch detection
- more flexibility in what to keep and what to delete
- maybe a GUI???

And that's pretty much it for now!
## ❤️ Support the Project

If this project has helped you, please consider showing your support! A small donation helps me dedicate more time to projects like this.
Thank you!

**[Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)**
Thanks for trying it and let me know how you like it!
