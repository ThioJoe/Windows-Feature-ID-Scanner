
define(['legacy/appViewManager', 'legacy/core'], (appViewManager, core) => {
    class HostedApplication {
        static _scaleRectCoordinates(rect) {
            let scaleFactor = 1;
            try {
                scaleFactor = Windows.Graphics.Display.DisplayInformation.getForCurrentView().rawPixelsPerViewPixel;   // System scale
            }
            catch (error) {
                scaleFactor = 1;
                CloudExperienceHost.Telemetry.logEvent("getSystemScaleFailure", core.GetJsonFromError(error));
            }

            let zoomFactor = window.devicePixelRatio / scaleFactor;    // zoom scale from ctrl+/-
            let scaledRect = {
                height: rect.height * zoomFactor,
                width: rect.width * zoomFactor,
                x: rect.left * zoomFactor,
                y: rect.top * zoomFactor
            };
            return scaledRect;
        }

        static _onResize(param) {
            try {
                let newClientRect = appViewManager.getBoundingClientRect();
                let newScaledRect = HostedApplication._scaleRectCoordinates(newClientRect);
                let hostedApplicationManager = CloudExperienceHostAPI.HostedApplicationCore.getForCurrentView();
                let currentLocation = hostedApplicationManager.windowLocation;
                if (newScaledRect !== currentLocation) {
                    hostedApplicationManager.windowLocation = newScaledRect;
                }
            }
            catch (error) {
                CloudExperienceHost.Telemetry.logEvent("showHostedAppAsyncNodePositionUpdateFailure", core.GetJsonFromError(error));
            }
        }

        launchShellHostedApplicationAsync(moduleName, targetRect, propertySetArgs) {
            const scaledRect = HostedApplication._scaleRectCoordinates(targetRect);

            if (!moduleName || !targetRect || !propertySetArgs) {
                CloudExperienceHost.Telemetry.logEvent("launchShellHostedApplicationAsyncFailedDueToInvalidArgs", JSON.stringify(moduleName, targetRect, propertySetArgs));
                return CloudExperienceHost.AppResult.fail;
            }

            const launchShellHostedApplicationPromise = CloudExperienceHostAPI.HostedApplicationCore.showOobeShellHostedAppAsync(moduleName, scaledRect, propertySetArgs)
                .then(hostedApplicationResult => {
                    appViewManager.undimChrome();

                    CloudExperienceHost.Telemetry.logEvent("launchShellHostedApplicationAsyncExitedWithResult", JSON.stringify(hostedApplicationResult));
                    return hostedApplicationResult.exitResult;
                }, (error) => {
                    appViewManager.undimChrome();

                    CloudExperienceHost.Telemetry.logEvent("launchShellHostedApplicationAsyncBridgeCallFailed", core.GetJsonFromError(error));
                    return CloudExperienceHost.AppResult.fail;
                });

            appViewManager.dimChrome();

            return launchShellHostedApplicationPromise;
        }

        requestDismissShellHostedApplication() {
            const manager = CloudExperienceHostAPI.HostedApplicationCore.getForCurrentView();

            if (!manager) {
                CloudExperienceHost.Telemetry.logEvent("requestDismissShellHostedApplicationFailedManagerUnavailable", core.GetJsonFromError(error));
                return false;
            }

            CloudExperienceHost.Telemetry.logEvent("requestDismissShellHostedApplication");
            manager.requestHostedAppDismiss();
            return true;
        }

        invokeMessageToShellHostedApplication(message) {
            const manager = CloudExperienceHostAPI.HostedApplicationCore.getForCurrentView();

            if (!manager) {
                CloudExperienceHost.Telemetry.logEvent("invokeMessageToShellHostedApplicationFailedManagerUnavailable", core.GetJsonFromError(error));
                return false;
            }

            CloudExperienceHost.Telemetry.logEvent("invokeMessageToShellHostedApplication", JSON.stringify(message));
            manager.invokeMessageToHostedApp(message);
            return true;
        }

        repositionShellHostedApplication(targetRect) {
            const manager = CloudExperienceHostAPI.HostedApplicationCore.getForCurrentView();

            if (!manager) {
                CloudExperienceHost.Telemetry.logEvent("repositionShellHostedApplicationFailedManagerUnavailable", core.GetJsonFromError(error));
                return false;
            }

            CloudExperienceHost.Telemetry.logEvent("repositionShellHostedApplication", JSON.stringify(targetRect));
            const scaledRect = HostedApplication._scaleRectCoordinates(targetRect);

            manager.windowLocation = scaledRect;
            return true;
        }

        launchAsyncWithNavigationCompletedCallback(currentNode, args, callback) {
            if (currentNode && currentNode.appUserModelId) {
                let clientRect = appViewManager.getBoundingClientRect();
                let scaledRect = HostedApplication._scaleRectCoordinates(clientRect);
                let showAppPromise = CloudExperienceHostAPI.HostedApplicationCore.showHostedAppAsync(currentNode.appUserModelId, currentNode.hostedApplicationProtocol, args, scaledRect);
                showAppPromise = showAppPromise.then(function (hostedApplicationResult) {
                    window.removeEventListener("resize", HostedApplication._onResize);
                    return hostedApplicationResult.exitResult;
                }, function (error) {
                    window.removeEventListener("resize", HostedApplication._onResize);
                    CloudExperienceHost.Telemetry.logEvent("showHostedAppAsyncFailure", core.GetJsonFromError(error));
                    return CloudExperienceHost.AppResult.fail;
                });

                window.addEventListener("resize", HostedApplication._onResize);
                appViewManager.dimChrome();
                let navigationCompletedEventArgs = new Object(); // Need to implement INavigationCompletedEventArgs
                navigationCompletedEventArgs.isSuccess = true; // boolean
                navigationCompletedEventArgs.webErrorStatus = Windows.Web.WebErrorStatus.unknown; // Windows.Web.WebErrorStatus
                navigationCompletedEventArgs.uri = "hostedapplication://" + currentNode.appUserModelId; // string
                callback(navigationCompletedEventArgs);
                return showAppPromise;
            }
            else {
                CloudExperienceHost.Telemetry.logEvent("showHostedAppAsyncNodeMisconfiguration", JSON.stringify(currentNode));
                return CloudExperienceHost.AppResult.fail;
            }
        }
    }
    return HostedApplication;
});
