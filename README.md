# LSC-Apps
LS Central app files by version.

1. Repository is needed when StrongPoint or customer extension has dependencies to LS Central in app.json file.
2. AL-Go build pipeline in your extension will fail if it has LS changes and you don't add LS Central app as dependency.
3. Select the needed LS version or upload a new one (name the folder as a version and put app.zip). Select LS version by opening app.zip file and copying the **raw link**

![image](https://github.com/user-attachments/assets/042349a1-97ab-480c-be9a-cefab5e9ea7a)

4. Paste the link in your extension's **/.github/AL-Go-Settings.json** file in parameter "installApps", for example 25.0 version:  
"installApps": [
    "https://github.com/StrongPointLT-ERP/LSC-Apps/raw/refs/heads/main/LS%20Central/25.0/app.zip"
  ]
5. app.zip contains two app files - "LS Central" and "LS Central System App". Might be updated with Test app in the future.
6. Non LS dependencies should be stored in a folder like "installApps" in your extension. You can also store LS apps there, but we use this repository so that all extensions which have LS dependencies would use same LS app files when building. And also having one place where to store LS versions saves a disk space on GitHub account.
