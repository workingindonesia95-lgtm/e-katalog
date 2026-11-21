; Inno Setup script - E-Katalog Importbox
; Letakkan di folder root proyek (sejajar pubspec.yaml), lalu buka dengan Inno Setup > Compile.
; Jalankan dulu:  flutter build windows --release
; Setiap rilis: ubah AppVersion di bawah agar sama dengan pubspec.yaml.

#define AppName    "E-Katalog Importbox"
#define AppVersion "1.1.3"
#define AppExe     "e_katalog.exe"
#define BuildDir   "build\windows\x64\runner\Release"

[Setup]
; AppId jangan diubah lagi setelah dirilis (penanda aplikasi yang sama saat upgrade)
AppId={{E441EDDD-A8FA-4D8E-A2DF-0BCB4015954F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Importbox
; Dipasang per-pengguna: tanpa izin admin, sehingga pembaruan otomatis bisa menimpa file
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\E-Katalog
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=installer_output
OutputBaseFilename=E-Katalog-Setup-{#AppVersion}
SetupIconFile=assets\logo\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Buat ikon di Desktop"; GroupDescription: "Pintasan:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Jalankan {#AppName}"; Flags: nowait postinstall skipifsilent
