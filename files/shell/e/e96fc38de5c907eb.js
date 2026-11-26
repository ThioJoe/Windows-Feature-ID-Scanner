define(["lib/knockout", 'corejs/knockouthelpers', "legacy/bridge", "legacy/core", "legacy/appObjectFactory"], (ko, KoHelpers, bridge, core, appObjectFactory) => {
    const retailDemoEnableTapCount = 5;
    const retailDemoEnableSpaceCount = 10;
    const retailDemoEnableTapTimeout = 2000;
    const enterpriseProvisioningEnableWinKeyCount = 5;
    class GestureManager {
        constructor() {
            this.resetTapCountAndTime();
            this.spacebarPressCount = 0;
            this.allowRetailDemoEntrypoint = true;
            this.headerVM = null;
            this.winKeyPressCount = 0;
            this.watcher = Windows.Devices.Enumeration.DeviceInformation.createWatcher(Windows.Devices.Enumeration.DeviceClass.portableStorageDevice);
        }

        reevaluateRetailDemoEntryAllowed() {
            let isRetailDemoSuppported = false;

            try {
                isRetailDemoSuppported = RetailDemo.Internal.RetailDemoSetup.isSupported;
            }
            catch (err) {
            }

            return bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", "retailDemoEnabled").then((result) => {
                this.allowRetailDemoEntrypoint = result ? false : isRetailDemoSuppported;
                return this.allowRetailDemoEntrypoint;
            }, (err) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "GetSharableDataRetailDemoEnabledFailure", core.GetJsonFromError(err));
                this.allowRetailDemoEntrypoint = isRetailDemoSuppported;
                return this.allowRetailDemoEntrypoint;
            });
        }

        resetTapCountAndTime() {
            this.retailDemoTapCount = 0;
            this.retailDemoPreviousTapTime = 0;
        }

        onTitleClicked() {
            let nowTime = Date.now();
            if ((nowTime - this.retailDemoPreviousTapTime) > retailDemoEnableTapTimeout) {
                this.resetTapCountAndTime();
            }

            this.retailDemoPreviousTapTime = nowTime;
            if (++this.retailDemoTapCount === retailDemoEnableTapCount) {
                this.resetTapCountAndTime();
                this.retailDemoGestureDetected();
            }
        }

        setHeaderVM(headerVM) {
            this.headerVM = headerVM;
        }

        disableRetailDemoEntryPoint() {
            if (this.headerVM) {
                this.headerVM.disableRetailDemoEntryPoint();
            }
            this.allowRetailDemoEntrypoint = false;
        }

        retailDemoGestureDetected() {
            KoHelpers.registerDialogComponents();
            let dialogElement = document.querySelector("oobe-retaildemo-dialog");
            if (!dialogElement) {
                dialogElement = document.createElement("oobe-retaildemo-dialog");
                ko.applyBindings({}, dialogElement);
                document.body.appendChild(dialogElement);
            }
            KoHelpers.waitForDialogComponentLoadAsync().then(() => {
                dialogElement.koComponent.showDlg(false);
            });
        }

        onKeyUp(ev) {
            this.enterpriseProvisioningHandleHotKey(ev);

            if (this.allowRetailDemoEntrypoint) {
                this.retailDemoHandleHotKey(ev, true);
            }
        }

        onKeyDown(ev) {
            if (this.allowRetailDemoEntrypoint) {
                this.retailDemoHandleHotKey(ev, false);
            }
        }

        retailDemoHandleHotKey(ev, up) {
            if (up) {
                if (ev.ctrlKey && ev.altKey && ((ev.keyCode == WinJS.Utilities.Key.space) || (ev.key == "Spacebar"))) {
                    this.spacebarPressCount++;
                    ev.preventDefault();
                }
                else if (ev.keyCode != WinJS.Utilities.Key.space) {
                    this.spacebarPressCount = 0;
                }

                if (this.spacebarPressCount === retailDemoEnableSpaceCount) {
                    this.spacebarPressCount = 0;
                    this.retailDemoGestureDetected();
                }
            }
            else if ((ev.keyCode == WinJS.Utilities.Key.space) && ev.ctrlKey && ev.altKey) {
                ev.preventDefault();
            }
        }

        enterpriseProvisioningHandleHotKey(ev) {
            if (ev.keyCode == 91) {
                this.winKeyPressCount++;
                if (this.winKeyPressCount === enterpriseProvisioningEnableWinKeyCount) {
                    this.winKeyPressCount = 0;
                    bridge.fireEvent(CloudExperienceHost.Events.done, "OobeEnterpriseProvisioning");
                }
            } else if (this.winKeyPressCount > 0) {
                this.winKeyPressCount = 0;
            }
        }

        initiateAutoPilotDownloadAsync() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "populateAutoPilotPolicyStarted");
            let startTime = performance.now();
            let populateAutoPilotPoliciesPromise = new WinJS.Promise(EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.retrieveSettingsAsync().then(() => {
                let details = { timeElapsed: performance.now() - startTime };
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "populateAutoPilotPolicyReturned", JSON.stringify(details));
            }, (error) => {
                let errorJson = core.GetJsonFromError(error);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "populateAutoPilotPolicyFailure", errorJson);
            }));

            setImmediate(() => { populateAutoPilotPoliciesPromise });
        }

        startPortableDeviceWatcher() {
            this.initiateAutoPilotDownloadAsync();

            this.watcher.addEventListener("added", this.onPortableDeviceAdded.bind(this));

            this.watcher.addEventListener("updated", this.onPortableDeviceUpdated);
            this.watcher.addEventListener("removed", this.onPortableDeviceRemoved);

            this.watcher.start();
        }

        onPortableDeviceAdded(devInfo) {
            bridge.invoke("CloudExperienceHost.Storage.SharableData.getValue", "hasProvisionedThisSession").then((hasProvisioned) => {
                if (!hasProvisioned) {
                    let pluginManager = new CloudExperienceHostAPI.Provisioning.PluginManager();
                    pluginManager.getPackagesFromProvidersAsync().then((packages) => {
                        if (packages.length == 1) {
                            this.invokeProvisioningFromPortableDrive(true);
                        }
                        else if (packages.length > 1){
                            this.invokeProvisioningFromPortableDrive(false);
                        }
                    });
                }
                else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "PortableDriveInsertedAfterProvisioning");
                }
            });
        }

        onPortableDeviceUpdated(devInfo) {
        }

        onPortableDeviceRemoved(devInfo) {
        }

        stopPortableDeviceWatcher() {
            this.watcher.removeEventListener("added", this.onPortableDeviceAdded);
            this.watcher.removeEventListener("updated", this.onPortableDeviceUpdated);
            this.watcher.removeEventListener("removed", this.onPortableDeviceRemoved);

            this.watcher.stop();
        }

        invokeProvisioningFromPortableDrive(silentNavigation) {
            if (silentNavigation) {
                bridge.fireEvent(CloudExperienceHost.Events.done, "OobeProvisioningEntry");
            }
            else {
                bridge.fireEvent(CloudExperienceHost.Events.done, "OobeEnterpriseProvisioning");
            }
        }
    }
    return new GestureManager();
});
