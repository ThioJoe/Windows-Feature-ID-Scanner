define(["lib/knockout", 'legacy/bridge', 'legacy/events', 'legacy/core', 'corejs/knockouthelpers'], (ko, bridge, constants, core, KoHelpers) => {
    class OobeSettingsData {
        commitSettings(settings, privacyConsentPresentationVersion) {
            try {
                bridge.fireEvent(CloudExperienceHost.Events.showProgressWhenPageIsBusy);

                bridge.invoke("CloudExperienceHost.UserManager.getUserId").then((userId) => {
                    let userObj = null;
                    if (userId) {
                        userObj = Windows.System.User.getFromId(userId);
                    }
                    this.commitSettingsForUser(userObj, settings, privacyConsentPresentationVersion);
                }, (err) => {
                    this.commitSettingsForUser(null, settings, privacyConsentPresentationVersion);
                });
            }
            catch (err) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitSettingsFailure", core.GetJsonFromError(err));
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            }
        }

        commitSettingsForUser(userObj, settings, privacyConsentPresentationVersion) {
            CloudExperienceHostAPI.OobeSettingsStaticsCore.commitSettingsAsyncForUser(userObj, settings, privacyConsentPresentationVersion).done(function () {
                for (let setting of settings) {
                    bridge.invoke("CloudExperienceHost.Telemetry.logEvent", setting.canonicalName, setting.value);
                }
                bridge.fireEvent(constants.Events.done, constants.AppResult.success);
            },
            function (err) {
                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CommitSettingsAsyncWorkerFailure", core.GetJsonFromError(err));
                bridge.fireEvent(constants.Events.done, constants.AppResult.error);
            });
        }

        initializeLearnMoreContentAsync() {
            return CloudExperienceHostAPI.OobeSettingsManagerStaticsCore.getLearnMorePlainTextAsync().then((result) => {
                this.learnMoreContent = result;
            });
        }

        getLearnMoreContent() {
            return this.learnMoreContent;
        }

        updateLearnMoreContentForRender(iFrameElement, doc, dirVal, isInternetAvailable, errorMessage, targetPersonality, elementToAnchor) {
            let cssOverride = this.getCssOverride(targetPersonality);

            if (cssOverride && (cssOverride !== "")) {
                let fileRef = doc.head.ownerDocument.createElement("link");
                fileRef.setAttribute("rel", "stylesheet");
                fileRef.setAttribute("href", cssOverride);
                if (elementToAnchor) {
                    fileRef.onload = function() {
                        doc.location.href = "#" + elementToAnchor;
                    }
                }
                doc.head.appendChild(fileRef);
            }
            else if (elementToAnchor) {
                doc.location.href = "#" + elementToAnchor;
            }

            let privacyLinks = doc.querySelectorAll("a");
            for (let i = 0; i < privacyLinks.length; i++) {
                let link = privacyLinks[i];
                link.onclick = (e) => {
                    this.showLearnMoreContent(iFrameElement, doc, e.target.href, dirVal, isInternetAvailable, errorMessage, targetPersonality);
                    e.preventDefault();
                };
            }
        }

        getCssOverride(targetPersonality) {
            if (targetPersonality === CloudExperienceHost.TargetPersonality.InclusiveBlue) {
                return "/webapps/inclusiveOobe/css/inclusive-mseula.css";
            }
            else if (targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite) {
                return "/webapps/inclusiveOobe/css/light-iframe-content.css";
            }
            return "";
        }

        showLearnMoreContent(iFrameElement, doc, href, dirVal, isInternetAvailable, errorMessage, targetPersonality) {
            let cssOverride = this.getCssOverride(targetPersonality);

            if (isInternetAvailable) {
                let personalityQSParam = (targetPersonality === CloudExperienceHost.TargetPersonality.LiteWhite) ? "&profile=transparentLight" : "";
                let url = href + personalityQSParam;
                WinJS.xhr({ url: url }).then((response) => {
                    doc.location.href = url;
                    doc.body.focus();
                }, (error) => {
                    let html = "<html><head>";
                    if (cssOverride && (cssOverride !== "")) {
                        html = html + "<link href=\"" + cssOverride + "\" rel=\"stylesheet\">";
                    }
                    html = html + "</head><body><p>" + errorMessage + "</p></body></html>";
                    KoHelpers.loadIframeContent(iFrameElement, doc, { content: html, dir: dirVal });
                });
            }
            else {
                let innerHTML = "<html><head>";
                if (cssOverride && (cssOverride !== "")) {
                    innerHTML = innerHTML + "<link href=\"" + cssOverride + "\" rel=\"stylesheet\">";
                }
                innerHTML = innerHTML + "</head><body><p>" + errorMessage + "</p></body></html>";
                doc.body.innerHTML = innerHTML;
            }
        }
    }
    return new OobeSettingsData();
});
