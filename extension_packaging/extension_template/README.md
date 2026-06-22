# HM WorkFlow Extension Packaging Notes

This directory is not an installable HyperWorks extension. Build the generated
extension from the project root:

```bat
extension_packaging\build_extension.bat
```

The distributable extension folder and zip package are written to `dist/`.
Load `dist\HMWorkflow` after building, or unzip
`dist\HMWorkflow_<version>_HyperWorks_Extension.zip` and load the unzipped
`HMWorkflow` folder that contains `extension.xml`.
