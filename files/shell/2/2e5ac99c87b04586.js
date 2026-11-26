define(['lib/knockout', 'legacy/bridge', 'legacy/appObjectFactory', 'legacy/events', 'legacy/core', 'oobezdp-helpers',
    'optional!sample/Sample.Oobe.ZdpManager'],
    (ko, bridge, appObjectFactory, constants, core, oobeZdpHelpers) => {

    class ZdpViewModel {
        constructor(resourceStrings, targetPersonality) {
            this.resourceStrings = resourceStrings;
            this.hasExitBeenCalled = false;
            this.isSpeechInProgress = ko.observable(false);
            this.populateZTPPolicyCacheCompleted = ko.observable(false);

            this.isSpeechInProgress.extend({ notify: 'always' });
            this.populateZTPPolicyCacheCompleted.extend({ notify: 'always' });

            this.hasDoneEventFired = false;

            this.isSpeechInProgress.subscribe(() => {
                this.fireDoneEventIfNecessary();
            });
            this.populateZTPPolicyCacheCompleted.subscribe(() => {
                this.fireDoneEventIfNecessary();
            });

            this.isLiteWhitePersonality = ko.pureComputed(() => {
                return targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite;
            });

            this.progressText = ko.observable("");
            this.progressText.subscribe((newTitle) => {
                document.title = newTitle;
            });
            this.zdpStatus = CloudExperienceHostAPI.OobeZdpStatus.none;
            this.zdpManager = appObjectFactory.getObjectFromString("CloudExperienceHostAPI.OobeZdpManagerStaticsCore");

            this.statusMaps = {};
            this.statusMaps[CloudExperienceHostAPI.OobeZdpStatus.scanning] = new oobeZdpHelpers.ScanningStatusHandler(this);
            let downloadingAndInstallingStatusHandler = new oobeZdpHelpers.DownloadingAndInstallingStatusHandler(this);
            this.statusMaps[CloudExperienceHostAPI.OobeZdpStatus.downloading] = downloadingAndInstallingStatusHandler;
            this.statusMaps[CloudExperienceHostAPI.OobeZdpStatus.installing] = downloadingAndInstallingStatusHandler;
            this.statusMaps[CloudExperienceHostAPI.OobeZdpStatus.finished] = new oobeZdpHelpers.FinishedStatusHandler(this);
            this.statusMaps[CloudExperienceHostAPI.OobeZdpStatus.skipped] = new oobeZdpHelpers.SkippedStatusHandler(this);
            this.statusQueue = [];

            this.zdpManager.onstatuschanged = (status) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZDPStatusChanged", status);
                this.startTimer();
                this.statusQueue.push(status);
                this.processStatusQueue();
            };

            setImmediate(() => {
                this.startUpdate();
                this.populateZTPPolicyCache().done(() => {
                    this.populateZTPPolicyCacheCompleted(true);
                });
            });
        }

        fireDoneEventIfNecessary() {
            if ((this.isSpeechInProgress() == false) && (this.hasDoneEventFired == false) && this.hasExitBeenCalled && this.exitEvent && this.populateZTPPolicyCacheCompleted()) {
                this.hasDoneEventFired = true;
                if ((this.exitEvent === constants.AppResult.success) && this.isRebootRequired()) {
                    bridge.invoke("CloudExperienceHost.setRebootForOOBE");
                }
                this.dispose();
                if (this.exitTimer) {
                    clearTimeout(this.exitTimer);
                    this.exitTimer = null;
                }
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZDPExitEvent");
                bridge.fireEvent(constants.Events.done, this.exitEvent);
            }
        }

        populateZTPPolicyCache() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "populateZTPPolicyCacheStarted");
            let startTime = performance.now();
            let populateZTPCachePromise = EnterpriseDeviceManagement.Service.AutoPilot.AutoPilotUtilStatics.retrieveSettingsAsync().then(() => {
                let details = { timeElapsed: performance.now() - startTime };
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeZTPCacheReturned", JSON.stringify(details));
            }, (error) => {
                let errorJson = core.GetJsonFromError(error);
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeZTPCacheFailure", errorJson);
            });
            let timedOut = false;
            let timeoutPromise = WinJS.Promise.timeout(36000 /*36 second timeout*/).then(() => { timedOut = true; });
            return WinJS.Promise.any([populateZTPCachePromise, timeoutPromise]).then((result) => {
                if (timedOut) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZTPPolicyCacheTimeout");
                }
                else {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZTPPolicyCacheAttemptDone");
                }
            });
        }

        dispose() {
            this.cancelTimer();
            this.zdpManager.onstatuschanged = null;
        }

        onProgressTextChange(newTextResID) {
            this.progressText(resourceStrings[newTextResID]);
        }

        processStatusQueue() {
            if (!this.processQueueIntervalID) {
                this.processStatusQueueItem();
                this.processQueueIntervalID = setInterval(() => {
                    this.processStatusQueueItem();
                }, oobeZdpHelpers.constants.interval);
            }
        }

        processStatusQueueItem() {
            if (this.statusQueue.length > 0) {
                let status = this.statusQueue.shift();
                if (this.zdpStatus != CloudExperienceHostAPI.OobeZdpStatus.none) {
                    this.statusMaps[this.zdpStatus].leave(status);
                }
                this.statusMaps[status].enter(this.zdpStatus, status);
                this.zdpStatus = status;
            }
            else {
                clearInterval(this.processQueueIntervalID);
                this.processQueueIntervalID = null;
            }
        }

        startUpdate() {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "oobeZDPUpdateStarted");
            this.zdpManager.startUpdateAsync().done(() => { },
                (error) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZDPUpdateFailure", core.GetJsonFromError(error));
                this.exit(constants.AppResult.fail);
            });
            this.startTimer();
        }

        exit(event) {
            this.hasExitBeenCalled = true;
            this.exitEvent = event;
            this.exitTimer = setTimeout(() => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZDPExitTimerFired");
                this.isSpeechInProgress(false);
            }, 5000);
        }

        cancelUpdate() {
            this.zdpManager.cancelUpdateAsync().done(() => { /* success do nothing */ },
                (error) => {
                    this.exit(constants.AppResult.cancel);
                });
        }

        startTimer() {
            this.cancelTimer();
            this.cancelTimerID = setTimeout(() => {
                this.cancelUpdate();
            }, oobeZdpHelpers.constants.zdpTimeout);
        }

        cancelTimer() {
            if (this.cancelTimerID) {
                clearTimeout(this.cancelTimerID);
                this.cancelTimerID = null;
            }
        }

        showPage() {
            bridge.fireEvent(constants.Events.visible, true);
        }

        isRebootRequired() {
            if (!this.rebootRequired) {
                this.rebootRequired = this.zdpManager.rebootRequired;
            }
            return this.rebootRequired;
        }

        onSpeechError(error) {
            this.isSpeechInProgress(false);
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "ZDPVoiceOverError", core.GetJsonFromError(error));
        }

        onSpeechComplete() {
            this.isSpeechInProgress(false);
        }

        onSpeechStarting() {
            this.isSpeechInProgress(true);
        }
    }
    return ZdpViewModel;
});
