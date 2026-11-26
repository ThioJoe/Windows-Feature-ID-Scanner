
(function () {
    "use strict";
    var cortanaResources = {};
    var bridge = new CloudExperienceHost.Bridge();
    var market = "";
    var region = "";
    var isProgressWaiting = false;

    function showLearnMoreFlyout() {
        if (isProgressWaiting) {
            return;
        }

        bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Learn more link clicked").done(function (result) {
        }, function (e) {
        });

        var flyoutButton = document.getElementById("learnMoreLink"); // anchor
        var flyout = document.getElementById("learnMoreFlyout"); // flyout div
        flyout.style.width = "456px";
        flyout.style.marginTop = getPageTop(document.getElementById("_pageContent")) + "px";
        flyout.winControl.show(flyoutButton, "top", "left");
    }

    function getPageTop(el) {
        var rect = el.getBoundingClientRect();
        var docEl = document.documentElement;
        return rect.top + (window.pageYOffset || docEl.scrollTop || 0);
    }

    function isPsuedoLocale() 
    {
        return ["qps-ploc", "qps-ploca", "qps-plocm", "qps-Latn-x-sh"].findIndex(x => x === market) >= 0;
    }

    function isMarketSupported()
    {
        var marketSupported = (["en-us", "zh-cn", "zh-hans-cn", "en-gb", "fr-fr", "it-it", "de-de", "es-es", "ja", "pt-br", "es-mx", "fr-ca"].findIndex(x => x === market) >= 0);
        return (isPsuedoLocale() || marketSupported);
    }

    function isRegionSupported()
    {
        var supportedRegions = ["us", "au", "br", "ca", "cn", "fr", "de", "in", "it", "jp", "mx", "es", "gb"];
        return supportedRegions.findIndex(x => x === region) >= 0;
    }

    WinJS.UI.Pages.define("/views/cortana.html", {
        init: function (element, options) {
            var languagePromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getPreferredLang").then(function (preferredLang) {
                market = preferredLang.toLowerCase();
                _htmlRoot.setAttribute("lang", preferredLang);
            }, function () { });
            var regionPromise = bridge.invoke("CloudExperienceHost.Globalization.GeographicRegion.getCode").then(function (r) {
                region = r.toLowerCase();
            });
            var dirPromise = bridge.invoke("CloudExperienceHost.Globalization.Language.getReadingDirection").then(function (dirVal) {
                _htmlRoot.setAttribute("dir", dirVal);
            }, function () { });
            var stringPromise = bridge.invoke("CloudExperienceHost.Cortana.localizedStrings").then(function (result) {
                    cortanaResources = JSON.parse(result);
            });
            var cssPromise = uiHelpers.LoadCssPromise(document.head, "..", bridge);
            return WinJS.Promise.join({ languagePromise, regionPromise, dirPromise, stringPromise, cssPromise });
        },

        ready: function (element, options) {
            var setContentFor = [cortanaIntro, cortanaPersonaText, cortanaContent, setCortanaOptOut, learnMoreLink, cortanaNextButton, learnMoreHeadline, learnMoreBody, learnMoreBody2];
            for (var i = 0; i < setContentFor.length; i++) {
                setContentFor[i].innerHTML = cortanaResources[setContentFor[i].id];
            }

            setCortanaOptOut.onclick = function () {
                if (isProgressWaiting) {
                    return;
                }

                _setProgressState(true);

                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Cortana user clicked opt out").done(function (result) {
                }, function (e) {
                });
                bridge.invoke("CloudExperienceHost.Cortana.setCortanaOptin", 0).done(function () {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.success);
                }, function (e) {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
                });
            };

            cortanaNextButton.onclick = function () {
                _setProgressState(true);

                bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "Cortana user clicked opt in").done(function (result) {
                }, function (e) {
                });
                bridge.invoke("CloudExperienceHost.Cortana.setCortanaOptin", 1).done(function () {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.success);
                }, function (e) {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
                });
            };

            uiHelpers.RegisterEaseOfAccess(easeOfAccess, bridge);
            uiHelpers.RegisterInputSwitcher(inputSwitcher, bridge);

            learnMoreLink.addEventListener("click", showLearnMoreFlyout, false);

            var animation = document.getElementById("cortanaAnimation");
            if (market === "ja")
            {
                animation.src = "../media/CortanaAnimationJa.gif";
            }
            else
            {
                animation.src = "../media/CortanaAnimation.gif";
            }

            var text =
                [
                    cortanaResources['cortanaPersonaText2'],
                    cortanaResources['cortanaPersonaText3'],
                ];
            var textIndex = 0;
            var interval = setInterval(function () {
                if (textIndex >= text.length - 1) {
                    clearInterval(interval);
                }
                cortanaPersonaText.innerHTML = text[textIndex];
                textIndex++;
            }, 8000); //8 seconds for each set of text

            if (isMarketSupported() && isRegionSupported()) {
                bridge.invoke("CloudExperienceHost.Cortana.isCortanaAllowedByPolicy").done(function (result) {
                    if (result) {
                        bridge.fireEvent(CloudExperienceHost.Events.visible, true);
                    }
                    else {
                        bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.abort);
                    }
                }, function (e) {
                    bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.abort);
                });
            }
            else {
                bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.abort);
                return;
            }

            function _setProgressState(waiting) {
                isProgressWaiting = waiting;
                cortanaNextButton.disabled = waiting;
            }
        },
        error: function (e) {
            bridge.invoke("CloudExperienceHost.Telemetry.logEvent", "CortanaError", JSON.stringify({ number: e && e.number, stack: e && e.asyncOpSource && e.asyncOpSource.stack }));
            bridge.fireEvent(CloudExperienceHost.Events.done, CloudExperienceHost.AppResult.fail);
        }
    });
})();

