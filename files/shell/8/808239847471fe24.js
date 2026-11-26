"use strict";
var CloudExperienceHost;
(function (CloudExperienceHost) {
    class AppResult {
        static doesResultAllowExit(result) {
            return (result == AppResult.exitCxhFailure) || (result == AppResult.exitCxhSuccess) || (result == AppResult.success) || (result == AppResult.cancel);
        }
        static getExternalAppResult(result) {
            switch (result) {
                case AppResult.exitCxhFailure:
                    return AppResult.fail;
                case AppResult.exitCxhSuccess:
                    return AppResult.success;
                default:
                    return result;
            }
        }
    }
    AppResult.success = "success";
    AppResult.fail = "fail";
    AppResult.cancel = "cancel";
    AppResult.abort = "abort";
    AppResult.offline = "offline";
    AppResult.preloadSkip = "preloadSkip";
    AppResult.action1 = "action1";
    AppResult.action2 = "action2";
    AppResult.action3 = "action3";
    AppResult.exitCxhFailure = "exitCxhFailure";
    AppResult.exitCxhSuccess = "exitCxhSuccess";
    AppResult.error = "error";
    CloudExperienceHost.AppResult = AppResult;
    class InternalAppResult {
    }
    InternalAppResult.back = "back";
    InternalAppResult.navigateWithBackstack = "navigateWithBackstack";
    CloudExperienceHost.InternalAppResult = InternalAppResult;
    class SignInIdentityProviders {
    }
    SignInIdentityProviders.Local = "CXH.IDPS.Local";
    SignInIdentityProviders.MSA = "CXH.IDPS.MSA";
    SignInIdentityProviders.AAD = "CXH.IDPS.AAD";
    CloudExperienceHost.SignInIdentityProviders = SignInIdentityProviders;
    class Events {
    }
    Events.navigate = "CloudExperienceHost.navigate";
    Events.visible = "CloudExperienceHost.visible";
    Events.goBack = "CloudExperienceHost.goBack";
    Events.retryApp = "CloudExperienceHost.retryApp";
    Events.skipApp = "CloudExperienceHost.skipApp";
    Events.done = "CloudExperienceHost.done";
    Events.showEaseOfAccessControl = "CloudExperienceHost.showEaseOfAccessControl";
    Events.languageChange = "CloudExperienceHost.languageChange";
    Events.updateFrameDirection = "CloudExperienceHost.updateFrameDirection";
    Events.resetFooterFocus = "CloudExperienceHost.resetFooterFocus";
    Events.inputSwitchIndicatorChange = "CloudExperienceHost.inputSwitchIndicatorChange";
    Events.loadIdentityProvider = "CloudExperienceHost.loadIdentityProvider";
    Events.postTicketToReturnUrl = "CloudExperienceHost.postTicketToReturnUrl";
    Events.postDeviceTicketToUrl = "CloudExperienceHost.postDeviceTicketToUrl";
    Events.postSharedAccountRegistrationTicketsToUrl = "CloudExperienceHost.postSharedAccountRegistrationsTicketsToUrl";
    Events.registerNGCForUser = "CloudExperienceHost.registerNgcForUser";
    Events.resetNGCForUser = "CloudExperienceHost.resetNgcForUser";
    Events.backButtonClicked = "CloudExperienceHost.backButtonClicked";
    Events.showProgressWhenPageIsBusy = "CloudExperienceHost.showProgressWhenPageIsBusy";
    Events.unhandledException = "CloudExperienceHost.unhandledException";
    Events.reportTargetedContentInteraction = "CloudExperienceHost.reportTargetedContentInteraction";
    Events.windowsUpdateStatus = "CloudExperienceHost.ExpeditedUpdate.windowsUpdateStatus";
    CloudExperienceHost.Events = Events;
})(CloudExperienceHost || (CloudExperienceHost = {}));
if ((typeof define === "function") && define.amd) {
    define(function () {
        return { Events: CloudExperienceHost.Events, AppResult: CloudExperienceHost.AppResult };
    });
}
