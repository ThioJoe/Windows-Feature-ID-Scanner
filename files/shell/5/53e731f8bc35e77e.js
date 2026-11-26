"use strict";
var CloudExperienceHost;
((CloudExperienceHost) => {
    var EnterpriseNgcEnrollment;
    ((EnterpriseNgcEnrollment) => {
        var enterpriseNgcEnrollmentResources = {};
        var bridge = new CloudExperienceHost.Bridge();
        var isLiteWhitePersonality = false;

        WinJS.UI.Pages.define("/webapps/enterprisengcenrollment/views/enterpriseNgcEnrollment.html", {
            init: (element, options) => {
                var languagePromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getPreferredLang").then((preferredLang) => {
                    _htmlRoot.setAttribute("lang", preferredLang);
                }, () => { });
                var dirPromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getReadingDirection").then((dirVal) => {
                    _htmlRoot.setAttribute("dir", dirVal);
                }, () => { });
                var keyList = ['Title', 'Body', 'BodyHello', 'HelpLink', 'HelpHeadline', 'HelpBody', 'PadlockTitle', 'SetUpPinButton', 'OkButton',
                           'TitleCancel', 'BodyCancel', 'BodyHelloCancel', 'TitleSuccess', 'BodySuccess', 'TitleError', 'BodyError', 'BodyTpmError',
                           'BodyServerError', 'SpecialErrorInfo', 'ErrorDescription', 'ErrorCode', 'CorrelationID', 'Timestamp', 'TryAgainButton',
                           'CancelButton'];
                var stringPromise = bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "enterpriseNgcEnrollment", keyList).then((result) => {
                    enterpriseNgcEnrollmentResources = JSON.parse(result);
                });
                var cssPromise = uiHelpers.LoadCssPromise(document.head, "../../..", bridge);
                var personalityPromise = bridge.invoke("CloudExperienceHost.getContext").then(function (result) {
                    isLiteWhitePersonality = (result.personality === CloudExperienceHost.TargetPersonality.LiteWhite);
                });
                return WinJS.Promise.join({ languagePromise: languagePromise, dirPromise: dirPromise, stringPromise: stringPromise, cssPromise: cssPromise, personalityPromise: personalityPromise });
            },
            ready: (element, options) => {

                var pageElementsWithTextContent = [Title, HelpLink, HelpHeadline, HelpBody, PadlockTitle, SpecialErrorInfo,
                                                   ErrorDescription, ErrorCode, CorrelationID, Timestamp];
                for (var i = 0; i < pageElementsWithTextContent.length; i++) {
                    pageElementsWithTextContent[i].textContent = enterpriseNgcEnrollmentResources[pageElementsWithTextContent[i].id];
                }

                HelpLink.addEventListener("click", _showHelpFlyout, false);

                SetUpPinButton.addEventListener("click", ((event) => {
                    event.preventDefault();
                    SetUpPinButton.disabled = true;
                    _onSetUpPin.apply(this);
                }).bind(this));

                OkButton.addEventListener("click", ((event) => {
                    event.preventDefault();
                    OkButton.disabled = true;
                    _onOk.apply(this);
                }).bind(this));

                TryAgainButton.addEventListener("click", ((event) => {
                    event.preventDefault();
                    _onTryAgain.apply(this);
                }).bind(this));

                CancelButton.addEventListener("click", ((event) => {
                    event.preventDefault();
                    CancelButton.disabled = true;
                    _onCancel.apply(this);
                }).bind(this));

                var buttonsWithAccessKeys = [SetUpPinButton, OkButton, TryAgainButton, CancelButton];
                buttonsWithAccessKeys.forEach((eachElement) => {
                    var result = CloudExperienceHost.ResourceManager.GetContentAndAccesskey(enterpriseNgcEnrollmentResources[eachElement.id]);
                    eachElement.textContent = result.content;
                    eachElement.accessKey = result.accessKey;
                });

                if (isLiteWhitePersonality) {
                    _setVisibility(PagePadlock, false);
                    _setVisibility(easeOfAccess, false);
                    _setVisibility(inputSwitcher, false);
                    _setVisibility(HelpLink, true, 'inline-block');
                    ContainerDiv.classList.remove('container-content');
                }
                else {
                    uiHelpers.RegisterEaseOfAccess(easeOfAccess, bridge);
                    uiHelpers.RegisterInputSwitcher(inputSwitcher, bridge);
                }

                var helloSuccessful = false;
                bridge.invoke("CloudExperienceHost.EnterpriseNgcEnrollment.didHelloEnrollmentSucceed").done((success) => {

                    helloSuccessful = success;

                    if (success) {
                        Body.textContent = enterpriseNgcEnrollmentResources['BodyHello'];

                        _setVisibility(HelpLink, false);
                        _setVisibility(PagePadlock, false);
                    }
                    else {
                        Body.textContent = enterpriseNgcEnrollmentResources['Body'];
                    }
                }, (e) => {
                    Body.textContent = enterpriseNgcEnrollmentResources['Body'];
                });

                _setVisibility(PageSpinner, false);
                _setVisibility(PageError, false);
                _setVisibility(OkButton, false);
                _setVisibility(CancelButton, false);

                SetUpPinButton.focus();

                function _onSetUpPin() {

                    _setVisibility(SetUpPinButton, false);
                    _setVisibility(Title, false);
                    _setVisibility(PageBody, false);
                    _setVisibility(PagePadlock, false);
                    _setVisibility(PageEnrollment, false);
                    _setVisibility(PageSpinner, !isLiteWhitePersonality);

                    bridge.invoke("CloudExperienceHost.EnterpriseNgcEnrollment.enrollForNgc").done((GUID) => {
                        _showSuccessPage();
                    }, (e) => {
                        _makeErrorDecision(e);
                    });
                }
                function _onOk() {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_Success");
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.success);
                }
                function _onCancel() {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_Cancelled");
                    bridge.invoke("CloudExperienceHost.HelloCleanup.cleanupHelloEnrollment");
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
                }
                function _onTryAgain() {

                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_TryAgain");

                    Title.textContent = enterpriseNgcEnrollmentResources['Title'];

                    if (helloSuccessful) {
                        Body.textContent = enterpriseNgcEnrollmentResources['BodyHello'];

                        _setVisibility(PagePadlock, false);
                    }
                    else {
                        Body.textContent = enterpriseNgcEnrollmentResources['Body'];

                        _setVisibility(HelpLink, true, 'inline-block');
                        _setVisibility(PagePadlock, !isLiteWhitePersonality);
                    }

                    SetUpPinButton.disabled = false;

                    _setVisibility(PageError, false);
                    _setVisibility(CancelButton, false);
                    _setVisibility(PageEnrollment, true);
                    _setVisibility(SetUpPinButton, true);

                    SetUpPinButton.focus();
                }
                function _showSuccessPage() {

                    Title.textContent = enterpriseNgcEnrollmentResources['TitleSuccess'];
                    Body.textContent = enterpriseNgcEnrollmentResources['BodySuccess'];

                    _setVisibility(PageSpinner, false);
                    _setVisibility(PagePadlock, false);
                    _setVisibility(HelpLink, false);
                    _setVisibility(PageEnrollment, true);
                    _setVisibility(Title, true, 'inline-block');
                    _setVisibility(PageBody, true, 'inline-block');
                    _setVisibility(OkButton, true);

                    OkButton.focus();
                }
                function _showForcedCreationPage() {

                    Title.textContent = enterpriseNgcEnrollmentResources['TitleCancel'];

                    if (helloSuccessful) {
                        Body.textContent = enterpriseNgcEnrollmentResources['BodyHelloCancel'];
                    }
                    else {
                        Body.textContent = enterpriseNgcEnrollmentResources['BodyCancel'];
                    }

                    SetUpPinButton.disabled = false;

                    _setVisibility(PageSpinner, false);
                    _setVisibility(PagePadlock, false);
                    _setVisibility(HelpLink, false);
                    _setVisibility(PageEnrollment, true);
                    _setVisibility(Title, true, 'inline-block');
                    _setVisibility(PageBody, true, 'inline-block');
                    _setVisibility(SetUpPinButton, true);

                    SetUpPinButton.focus();
                }
                function _makeErrorDecision(e) {
                    
                    var signedNumber = e.number;
                    if (signedNumber < 0) {
                        signedNumber = 0xFFFFFFFF + signedNumber + 1;
                    }

                    var hexErrorString = signedNumber.toString(16).toUpperCase();
                    if (hexErrorString === "80070032" ||
                        hexErrorString === "8009002D" ||
                        hexErrorString === "80090030" ||
                        hexErrorString === "80090031" ||
                        hexErrorString === "80090035" ||
                        hexErrorString === "80284001") {

                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_TpmError", hexErrorString);
                        _showErrorPage(enterpriseNgcEnrollmentResources['BodyTpmError'], hexErrorString);
                    }
                    else if (hexErrorString.substring(0, 5) === "80072") {

                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_ServerError", hexErrorString);
                        _showErrorPage(enterpriseNgcEnrollmentResources['BodyServerError'], hexErrorString);
                    }
                    else if (hexErrorString === "80090036")
                    {

                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_CancelledError", hexErrorString);
                        _showForcedCreationPage();
                    }
                    else {

                        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_Error", hexErrorString);
                        _showErrorPage(enterpriseNgcEnrollmentResources['BodyError'], hexErrorString);
                    }
                }
                function _showErrorPage(errorBody, errorString) {

                    Title.textContent = enterpriseNgcEnrollmentResources['TitleError'];
                    Body.textContent = errorBody;

                    ErrorCodeText.textContent = "0x" + errorString;

                    bridge.invoke("CloudExperienceHost.Telemetry.getId").done((id) => {
                        CorrelationIDText.textContent = id;
                    }, (e) => {
                        CorrelationIDText.textContent = "undefined";
                    });

                    var date = new Date(Date.now());
                    TimestampText.textContent = date.toISOString();

                    if (!isLiteWhitePersonality) {
                        PagePadlock.style.visibility = 'hidden';
                        PagePadlock.style.display = 'inline';
                    }

                    _setVisibility(PageSpinner, false);
                    _setVisibility(HelpLink, false);
                    _setVisibility(PageEnrollment, true);
                    _setVisibility(Title, true, 'inline-block');
                    _setVisibility(PageBody, true, 'inline-block');
                    _setVisibility(PageError, true);
                    _setVisibility(CancelButton, true);

                    CancelButton.focus();
                }
                function _showHelpFlyout() {

                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_HelpFlyout");

                    var flyoutButton = document.getElementById("HelpLink");
                    var flyout = document.getElementById("HelpFlyout");
                    flyout.style.marginTop = _getPageTop(document.getElementById("HelpLink")) + "px";
                    flyout.winControl.show(flyoutButton, "top", "left");
                }
                function _getPageTop(el) {
                    var rect = el.getBoundingClientRect();
                    var docEl = document.documentElement;
                    return rect.bottom + (window.pageYOffset || docEl.scrollTop || 0);
                }
                function _setVisibility(container, visible, displayProperty) {
                    container.style.visibility = (visible) ? 'visible' : 'hidden';
                    container.style.display = (displayProperty ? displayProperty : (visible ? 'inline' : 'none'));
                }
            },
            error: (e) => {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "EnterpriseNgcEnrollment_Error", CloudExperienceHost.GetJsonFromError(e));
                bridge.invoke("CloudExperienceHost.HelloCleanup.cleanupHelloEnrollment");
                bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
            },
        });
    })(EnterpriseNgcEnrollment = CloudExperienceHost.EnterpriseNgcEnrollment || (CloudExperienceHost.EnterpriseNgcEnrollment = {}));
})(CloudExperienceHost || (CloudExperienceHost = {}));
