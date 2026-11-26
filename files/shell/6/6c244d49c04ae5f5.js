(function () {
    "use strict";

    WinJS.UI.Pages.define("/views/tokenManagerErrorHandler.html", {
        ready: function (element, options) {
            document.getElementById("_okButton").addEventListener("click", function () {
                document.getElementById("_okButton").disabled = true;
                var msaUIHandler = options.msaUIHandler;
                msaUIHandler.saveAuthStateAndCompleteWebFlow(
                    CloudExperienceHost.AppResult.fail,
                    null /*requestId*/,
                    null /*puid*/,
                    null /*username*/,
                    null /*da*/,
                    null /*daCreation*/,
                    null /*daExpiration*/,
                    null /*sessionKey*/,
                    null /*flowToken*/,
                    options.hr,
                    options.hrInternal,
                    null /*sessionKeyType*/);
            }.bind(options));

            WinJS.Resources.processAll().done(function () {
                var title = null;
                var body = null;
                let HRESULT_ERROR_ACCESS_DISABLED_BY_POLICY = "0X800704EC";
                let HRESULT_ONL_E_REQUEST_THROTTLED = "0X80860010";
                let ERRORS_PIN_UNUSABLE = ["0X80090016", "0X80090010", "0X80090027", "0X80090011", "0X80090030", "0X8028008B", "0X8007139F"];
                let platform = CloudExperienceHost.Environment.getPlatform();
                let internalError = options.hrInternal;

               if ((internalError !== null) && (internalError.toUpperCase() === HRESULT_ERROR_ACCESS_DISABLED_BY_POLICY)) {
                    title = WinJS.Resources.getString("/errors/BlockedByPolicyMSATitle").value;
                    body = options.internalErrorDescription || null;
                } else if ((internalError !== null) && (ERRORS_PIN_UNUSABLE.indexOf(internalError.toUpperCase()) >= 0)) {
                    title = WinJS.Resources.getString("/errors/NoPinTitle").value;
                    body = WinJS.Resources.getString("/errors/NoPinText").value;
                } else if ((internalError !== null) && (internalError.toUpperCase() === HRESULT_ONL_E_REQUEST_THROTTLED)) {
                    title = WinJS.Resources.getString("/errors/Title").value;
                    body = WinJS.Resources.getString("/errors/RequestThrottledText").value;
                    document.getElementById("_okButton").textContent =  WinJS.Resources.getString("/errors/Retry").value;
                }
                else if (options.hasInternetAccess === false) {
                    title = WinJS.Resources.getString("/errors/NoNetworkMsaTitle").value;
                    body = WinJS.Resources.getString("/errors/NoNetworkMsaText").value;
                } else {
                    title = WinJS.Resources.getString("/errors/Title").value;
                    body = WinJS.Resources.getString("/errors/GenericMsaText").value;
                }

                document.getElementById("_title").textContent = title;
                document.getElementById("_errorText").textContent = body;
                document.getElementById("_errorCode").textContent = internalError;

                ["correlationId", "timeStamp"].forEach(function (field) {
                    let element = document.getElementById("_" + field);
                    if (options[field]) {
                        element.textContent = options[field];
                    }
                });

                if (platform === CloudExperienceHost.TargetPlatform.XBOX) {
                    document.getElementById("_feedback").style.display = 'none';
                }
            }.bind(options));
        },
    });
})();

