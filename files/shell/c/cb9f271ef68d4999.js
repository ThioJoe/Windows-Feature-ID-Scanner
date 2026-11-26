define(['lib/knockout', 'legacy/bridge',
    'optional!sample/Sample.CloudExperienceHostAPI.Speech.SpeechSynthesis'], (ko, bridge) => {

    let pendingPanelTransition = WinJS.Promise.as(null);

    let componentLoadCompleteCallback;
    let componentLoadingPromise = new WinJS.Promise((reportComplete) => {
        componentLoadCompleteCallback = reportComplete;
    });
    let pendingComponentLoads = 0;
    let preLoadHeldForAdditionalRegistrations = false;
    let initialComponentLoadComplete = false;
    function onComponentPreloaded(component) {
        if (!initialComponentLoadComplete && !preLoadHeldForAdditionalRegistrations && (--pendingComponentLoads == 0)) {
            initialComponentLoadComplete = true;
            setImmediate(() => {
                componentLoadCompleteCallback();
            });
        }
    }

    let dialogComponentLoadCompleteCallback;
    let dialogComponentLoadingPromise = new WinJS.Promise((reportComplete) => {
        dialogComponentLoadCompleteCallback = reportComplete;
    });
    let dialogPendingComponentLoads = 0;
    let dialogComponentLoadComplete = false;
    function onDialogComponentPreloaded(component) {
        if (!dialogComponentLoadComplete && --dialogPendingComponentLoads == 0) {
            dialogComponentLoadComplete = true;
            setImmediate(() => {
                dialogComponentLoadCompleteCallback();
            });
        }
    }

    function initializeIsGamepadEnabled() {
        let gamepadEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadEnabledOobe");
        return (gamepadEnabledObj.result && gamepadEnabledObj.value);
    }
    let gamepadEnabledOobe = initializeIsGamepadEnabled();

    function initializeIsGamepadLegendEnabled() {
        let gamepadLegendEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadLegendEnabled");
        return (gamepadLegendEnabledObj.result && gamepadLegendEnabledObj.value);
    }
    let gamepadLegendEnabled = initializeIsGamepadLegendEnabled();

    function initializeIsOOBEDeviceFormEnabled() {
        let deviceFormEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("OOBEDeviceForm");
        return (deviceFormEnabledObj.result && deviceFormEnabledObj.value);
    }
    let deviceFormEnabledOobe = initializeIsOOBEDeviceFormEnabled();

    let currentKeyInputModality;
    if (gamepadEnabledOobe && deviceFormEnabledOobe) {
        currentKeyInputModality = "keyboard";
        if (CloudExperienceHostAPI.Environment.deviceForm === CloudExperienceHost.TargetDevice.HANDHELD) {
            currentKeyInputModality = "gamepad";
        }

        document.addEventListener("keydown", (ev) => {
            let oldModality = currentKeyInputModality;

            if ((ev.keyCode >= WinJS.Utilities.Key.GamepadA) && (ev.keyCode <= WinJS.Utilities.Key.GamepadRightThumbstickLeft)) {
                currentKeyInputModality = "gamepad";
            }
            else {
                currentKeyInputModality = "keyboard";
            }

            if (oldModality !== currentKeyInputModality) {
                document.dispatchEvent(new Event("keyInputModalityChanged"))
            }
        }, { capture: true });
    }

    let componentsRegistered = false;
    let dialogComponentsRegistered = false;

    function isEnterKey(ev) {
        return (ev.keyCode == WinJS.Utilities.Key.enter);
    }

    function isPageDefaultActionAllowed(ev, lastSelectedElement) {
        if (isEnterKey(ev) && (ev.target == lastSelectedElement)) {
            let isLink = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "a");
            let isButton = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "button");
            let isSelect = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "select");
            if (!isLink && !isButton && !isSelect) {
                return true;
            }
        }
        return false;
    }

    function isPageActionAllowedWithGamepadA(ev, lastSelectedElement) {
        if (gamepadEnabledOobe && ev.keyCode == WinJS.Utilities.Key.GamepadA && ev.target == lastSelectedElement) {
            let isLink = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "a");
            let isButton = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "button");
            let isSelect = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "select");
            if (!isLink && !isButton && !isSelect) {
                return true;
            }
        }
        return false;
    }

    class KnockoutHelpers {
        registerComponents(scenarioMode, holdForAdditionalRegistration = false) {
            if (componentsRegistered) { Debug.break(); return; }
            if (holdForAdditionalRegistration) { preLoadHeldForAdditionalRegistrations = true; }

            let components_Default = {
                'default-progress': {},
                'default-contentView': {},
                'backstack-chrome-breadcrumb': {},
                'close-chrome-breadcrumb': {},
                'oobe-chrome-breadcrumb': {},
                'oobe-chrome-contentview': {},
                'oobe-chrome-footer': {},
                'oobe-progress': {},
                'oobe-light-contentview': {},
                'oobe-light-progress': {},
                'default-frame': {},
                'oobe-frame': {},
                'sspr-frame': {},
                'oobe-light-frame': {},
            };

            let components_InclusiveOobe = {
                'oobe-header': {},
                'oobe-footer': {},
                'oobe-button': {},
                'oobe-listview': {},
                'oobe-toggle': {},
                'oobe-textinput': {},
            };

            let components_Scoobe = {
                'common-header': {},
                'common-footer': {},
                'common-button': {},
                'common-listview': {},
                'common-toggle': {},
                'common-textinput': {},
            };

            let components_AOobe = {
                'oobe-header': {},
                'oobe-footer': {},
                'oobe-button': {},
                'oobe-textinput': {},
            };

            let components_LightProgress = {
                'oobe-progress': {},
                'oobe-light-progress': {},
            };

            let components_LightFooter = {
                'oobe-light-footer': {},
            };

            let componentsLookupTable = new Object();
            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.Default] = {
                components: components_Default,
                viewModelConfigPath: '',
                templateConfigPth: 'pageView/'
            };

            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.InclusiveOobe] = {
                components: components_InclusiveOobe,
                viewModelConfigPath: 'inclusiveOobeJsCommon/',
                templateConfigPth: 'inclusiveOobeViewTemplates/'
            };

            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.Scoobe] = {
                components: components_Scoobe,
                viewModelConfigPath: 'jsTemplates/',
                templateConfigPth: 'viewCommonTemplates/'
            };

            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.AOobe] = {
                components: components_AOobe,
                viewModelConfigPath: 'aOobeJsCommon/',
                templateConfigPth: 'aOobeViewTemplates/'
            };

            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.LightProgress] = {
                components: components_LightProgress,
                viewModelConfigPath: 'corejs/',
                templateConfigPth: 'coreView/'
            };

            componentsLookupTable[CloudExperienceHost.RegisterComponentsScenarioMode.LightFooter] = {
                components: components_LightFooter,
                viewModelConfigPath: 'corejs/',
                templateConfigPth: 'coreView/'
            };

            let components = componentsLookupTable[scenarioMode].components;

            let componentLoader = {
                getConfig: (name, callback) => {
                    let viewModelConfig = { require: componentsLookupTable[scenarioMode].viewModelConfigPath + name + '-vm' };
                    let templateConfig = { require: 'lib/text!' + componentsLookupTable[scenarioMode].templateConfigPth + name + '-template.html' };
                    callback({ viewModel: viewModelConfig, template: templateConfig, synchronous: true });
                },
                loadViewModel: (name, viewModelConfig, callback) => {
                    let viewModelConstructor = {
                        createViewModel: function (params, componentInfo) {
                            let vm = new viewModelConfig(params, componentInfo.element);
                            componentInfo.element.koComponent = vm;
                            return vm;
                        }
                    };
                    ko.components.defaultLoader.loadViewModel(name, viewModelConstructor, callback);
                }
            };
            ko.components.loaders.unshift(componentLoader);

            Object.keys(components).forEach((key) => {
                ko.components.register(key, components[key]);
            });

            Object.keys(components).forEach((key) => {
                pendingComponentLoads++;
                ko.components.get(key, onComponentPreloaded);
            });

            if (!holdForAdditionalRegistration) {
                preLoadHeldForAdditionalRegistrations = false;
                componentsRegistered = true;
            }
        }

        static registerDialogComponents() {
            if (dialogComponentsRegistered) { Debug.break(); return; }

            let customDialogComponents = {
                'oobe-retaildemo-dialog': {},
                'oobe-retaildemo-exit-dialog': {},
            };

            Object.keys(customDialogComponents).forEach((key) => {
                ko.components.register(key, customDialogComponents[key]);
            });

            Object.keys(customDialogComponents).forEach((key) => {
                dialogPendingComponentLoads++;
                ko.components.get(key, onDialogComponentPreloaded);
            });

            dialogComponentsRegistered = true;
        }

        static getElementIndex(element) {
            let index = 0;
            let parent = element.parentNode;
            if (parent && parent.children.length > 0) {
                for (let i = 0; i < parent.children.length; i++) {
                    if (element == parent.children[i]) {
                        index = i;
                        break;
                    }
                }
            }
            return index;
        }

        static waitForInitialComponentLoadAsync() {
            return componentLoadingPromise;
        }

        static waitForDialogComponentLoadAsync() {
            return dialogComponentLoadingPromise;
        }

        enableWinJSBinding(callback) {
            require(['lib/knockout-winjs'], callback);
        }

        static setFocusOnAutofocusElement() {
            let currentPanel = document.querySelector('.current-visible-panel');
            let autofocusElement = currentPanel ? currentPanel.querySelector("[autofocus='true']") : document.querySelector("[autofocus='true']");
            let firstInput = currentPanel ? currentPanel.querySelector("input") : null;
            if (autofocusElement) {
                autofocusElement.focus();
            } else if (firstInput) {
                firstInput.focus();
            }
        }

        static loadIframeContent(iFrameElement, iFrameDocument, value) {
            iFrameDocument.open('text/html', 'replace');
            iFrameDocument.write(value.content);
            iFrameDocument.close();

            if (gamepadEnabledOobe && deviceFormEnabledOobe) {
                let updateTabIndexBasedOnInputModality = () => {
                    if (currentKeyInputModality === "gamepad") {
                        iFrameElement.setAttribute("tabindex", "0");
                        WinJS.UI.XYFocus._iframeHelper.registerIFrame(iFrameElement);
                    }
                    else {
                        iFrameElement.removeAttribute("tabindex");
                        WinJS.UI.XYFocus._iframeHelper.unregisterIFrame(iFrameElement);
                    }
                };
                updateTabIndexBasedOnInputModality();
                document.addEventListener("keyInputModalityChanged", updateTabIndexBasedOnInputModality);
            }

            iFrameDocument.dir = value.dir;
            iFrameDocument.body.setAttribute("tabindex", "0");
            if (value.focusBody) {
                if (gamepadEnabledOobe && deviceFormEnabledOobe) {
                    if (currentKeyInputModality === "gamepad") {
                        iFrameElement.focus();
                    }
                    else {
                        iFrameDocument.body.focus();
                    }
                }
                else {
                    iFrameDocument.body.focus();
                }
            }

            if (value.addStyleSheet && (value.addStyleSheet !== "")) {
                let fileRef = iFrameDocument.head.ownerDocument.createElement("link");
                fileRef.setAttribute("rel", "stylesheet");
                fileRef.setAttribute("type", "text/css");
                fileRef.setAttribute("href", value.addStyleSheet);
                iFrameDocument.head.appendChild(fileRef);
            }

            if (value.frameTitle) {
                iFrameDocument.title = value.frameTitle;

                if (gamepadEnabledOobe && deviceFormEnabledOobe) {
                    iFrameElement.title = value.frameTitle;
                }
            }

            if (gamepadEnabledOobe && deviceFormEnabledOobe) {
                let setPseudoFocus = () => {
                    iFrameElement.classList.add("pseudo-focused");
                    iFrameDocument.body.classList.add("pseudo-focused");

                    if (gamepadLegendEnabled) {
                        bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "oobeCommon", ["GamepadButtonDeselect"]).done((result) => {
                            let resourceStrings = JSON.parse(result);
                            bridge.invoke("CloudExperienceHost.AppFrame.setGamepadLegendDisplayOverrideForB", resourceStrings.GamepadButtonDeselect);
                        });
                    }
                };

                let removePseudoFocus = () => {
                    iFrameElement.classList.remove("pseudo-focused");
                    iFrameDocument.body.classList.remove("pseudo-focused");

                    if (gamepadLegendEnabled) {
                        bridge.invoke("CloudExperienceHost.AppFrame.setGamepadLegendDisplayOverrideForB", null);
                    }
                };

                let lastObservedTarget;
                iFrameElement.addEventListener("keydown", (ev) => {
                    switch (ev.keyCode) {
                        case WinJS.Utilities.Key.enter:
                        case WinJS.Utilities.Key.GamepadA:
                            lastObservedTarget = ev.target;
                            break;

                        default:
                            break;
                    }
                    return true; // Tells Knockout to allow the default action
                });

                iFrameElement.addEventListener("keyup", (ev) => {
                    let handled = false;

                    switch (ev.keyCode) {
                        case WinJS.Utilities.Key.enter:
                            if (isPageDefaultActionAllowed(ev, lastObservedTarget)) {
                                value.pageDefaultAction();
                                handled = true;
                            }
                            break;

                        case WinJS.Utilities.Key.GamepadA:
                            if (ev.target === lastObservedTarget) {
                                setPseudoFocus();
                                iFrameDocument.body.focus();
                                handled = true;
                            }

                        default:
                            break;
                    }

                    return !handled;
                });

                let lastObservedTargetWithinIFrame;
                iFrameDocument.addEventListener("keydown", (ev) => {
                    let handled = false;
                    let goingUpOrLeft = false;

                    switch (ev.keyCode) {
                        case WinJS.Utilities.Key.enter:
                        case WinJS.Utilities.Key.GamepadB:
                            lastObservedTargetWithinIFrame = ev.target;
                            break;

                        case WinJS.Utilities.Key.GamepadLeftTrigger:
                            goingUpOrLeft = true;
                        case WinJS.Utilities.Key.GamepadRightTrigger:
                            if (iFrameElement.classList.contains("pseudo-focused")) {
                                iFrameDocument.body.scrollTop += (goingUpOrLeft ? -0.87 : 0.87) * iFrameDocument.defaultView.innerHeight;
                                handled = true;
                            }
                            break;

                        case WinJS.Utilities.Key.GamepadDPadUp:
                        case WinJS.Utilities.Key.GamepadLeftThumbstickUp:
                            goingUpOrLeft = true;
                        case WinJS.Utilities.Key.GamepadDPadDown:
                        case WinJS.Utilities.Key.GamepadLeftThumbstickDown:
                            if (iFrameElement.classList.contains("pseudo-focused")) {
                                iFrameDocument.body.scrollTop += (goingUpOrLeft ? -0.13 : 0.13) * iFrameDocument.defaultView.innerHeight;
                                handled = true;
                            }
                            break;

                        case WinJS.Utilities.Key.GamepadDPadLeft:
                        case WinJS.Utilities.Key.GamepadLeftThumbstickLeft:
                            goingUpOrLeft = true;
                        case WinJS.Utilities.Key.GamepadDPadRight:
                        case WinJS.Utilities.Key.GamepadLeftThumbstickRight:
                            if (iFrameElement.classList.contains("pseudo-focused")) {
                                iFrameDocument.body.scrollLeft += (goingUpOrLeft ? -0.13 : 0.13) * iFrameDocument.defaultView.innerWidth;
                                handled = true;
                            }
                            break;

                        default:
                            break;
                    }

                    return !handled;
                });

                iFrameDocument.addEventListener("keyup", (ev) => {
                    let handled = false;

                    switch (ev.keyCode) {
                        case WinJS.Utilities.Key.enter:
                            if (isPageDefaultActionAllowed(ev, lastObservedTargetWithinIFrame)) {
                                value.pageDefaultAction();
                                handled = true;
                            }
                            break;

                        case WinJS.Utilities.Key.GamepadB:
                            if (ev.target === lastObservedTargetWithinIFrame) {
                                removePseudoFocus();
                                iFrameElement.focus();

                                handled = true;
                            }
                            break;

                        default:
                            break;
                    }

                    return !handled;
                });

                iFrameDocument.addEventListener("focusin", (ev) => {
                    if (currentKeyInputModality === "gamepad") {
                        setPseudoFocus();
                    }
                    return true;
                }, { capture: true });

                iFrameDocument.addEventListener("focusout", (ev) => {
                    removePseudoFocus();
                    return true;
                }, { capture: true });
            }
            else {
                if (value.pageDefaultAction) {
                    let lastSelectedElement;
                    function enterKeyDownHandler(ev) {
                        if (isEnterKey(ev)) {
                            lastSelectedElement = ev.target;
                        }
                        return true; // Tells Knockout to allow the default action
                    }
                    iFrameDocument.addEventListener("keydown", enterKeyDownHandler);
                    function enterKeyUpHandler(ev) {
                        if (isPageDefaultActionAllowed(ev, lastSelectedElement)) {
                            value.pageDefaultAction();
                            return false;
                        }
                        return true; // Tells Knockout to allow the default action
                    }
                    iFrameDocument.addEventListener("keyup", enterKeyUpHandler);
                }
            }
        }
    };

    ko.bindingHandlers.panelIndexVisible = {
        init: function (element, valueAccessor) {
            let panelIndex = element.getAttribute("data-panel-index") || KnockoutHelpers.getElementIndex(element);
            Debug.assert(panelIndex !== undefined, "Panel binding couldn't find a panel index");
            let shouldDisplay = ko.unwrap(valueAccessor()) == panelIndex;
            element.style.display = shouldDisplay ? "" : "none";
            if (shouldDisplay) {
                element.classList.add("current-visible-panel");
            }
            document.dispatchEvent(new Event("panelChanged"));
        },
        update: function (element, valueAccessor, allBindings) {
            let panelIndex = element.getAttribute("data-panel-index") || KnockoutHelpers.getElementIndex(element);
            Debug.assert(panelIndex !== undefined, "Panel binding couldn't find a panel index");
            let shouldDisplay = ko.unwrap(valueAccessor()) == panelIndex;
            if (shouldDisplay) {
                element.classList.add("current-visible-panel");
                setImmediate(() => {
                    if (element.classList.contains("current-visible-panel")) {
                        pendingPanelTransition = pendingPanelTransition.then(() => {
                            if (element.style.display == "none") {
                                element.style.opacity = 0;
                                element.style.display = "";
                                document.dispatchEvent(new Event("panelChanged"));
                                let autoFocusItem = element.querySelector("[autofocus='true']");
                                let firstInput = element.querySelector("input");
                                if (autoFocusItem) {
                                    autoFocusItem.focus();
                                } else if (firstInput) {
                                    firstInput.focus();
                                }
                                return WinJS.UI.Animation.fadeIn(element);
                            }
                        });
                    }
                });
            }
            else {
                element.classList.remove("current-visible-panel");
                pendingPanelTransition = pendingPanelTransition.then(() => {
                    if (element.style.display != "none") {
                        return WinJS.UI.Animation.fadeOut(element).then(() => {
                            element.style.display = "none";
                        });
                    }
                });
            }
        }
    };

    ko.bindingHandlers.textVoiceOver = {
        update: function (element, valueAccessor, allBindings, viewModel, bindingContext) {
            let value = valueAccessor();
            let valueUnwrapped = ko.unwrap(value);

            if (valueUnwrapped && (valueUnwrapped.length > 0)) {
                let speechSynthesis = AppObjectFactory.getInstance().getObjectFromString("CloudExperienceHostAPI.Speech.SpeechSynthesis");
                speechSynthesis.speakAsync(valueUnwrapped, true /* useVoiceOver */, true /* checkSpeechControllerState */).done(() => {
                    if (typeof viewModel.onSpeechComplete === "function") {
                        viewModel.onSpeechComplete();
                    }
                }, (error) => {
                    if (typeof viewModel.onSpeechError === "function") {
                        viewModel.onSpeechError(error);
                    }
                }, (progressState) => {
                    if ((progressState == 10 /* SpeechProgressValue_Starting */) && (typeof viewModel.onSpeechStarting === "function")) {
                        viewModel.onSpeechStarting();
                    }
                });
            }

            ko.bindingHandlers.text.update(element, valueAccessor, allBindings, viewModel, bindingContext);
        }
    };

    ko.bindingHandlers.oobeHotKeys = {
        update: function (element, valueAccessor) {
            let supportHotKeys = ko.unwrap(valueAccessor());
            if (supportHotKeys) {
                require(['jsCommon/oobe-gesture-manager'], (gestureManager) => {
                    element.hotkeyDownHandler = gestureManager.onKeyDown.bind(gestureManager);
                    element.hotkeyUpHandler = gestureManager.onKeyUp.bind(gestureManager);
                    element.addEventListener("keydown", element.hotkeyDownHandler);
                    element.addEventListener("keyup", element.hotkeyUpHandler);
                });
            }
            else if (element.hotkeyDownHandler) {
                this.element.removeEventListener("keydown", element.hotkeyDownHandler);
                this.element.removeEventListener("keyup", element.hotkeyUpHandler);
                element.hotkeyDownHandler = null;
                element.hotkeyUpHandler = null;
            }
        }
    };

    ko.bindingHandlers.oobePageDefaultAction = {
        update: function (element, valueAccessor) {
            let defaultAction = ko.unwrap(valueAccessor());
            if (defaultAction) {
                let lastSelectedElement;
                function enterKeyDownHandler(ev) {
                    if (isEnterKey(ev)) {
                        lastSelectedElement = ev.target;
                    }
                    return true; // Tells Knockout to allow the default action
                }
                element.addEventListener("keydown", enterKeyDownHandler);
                function enterKeyUpHandler(ev) {
                    if (isPageDefaultActionAllowed(ev, lastSelectedElement)) {
                        defaultAction();
                        return false;
                    }

                    if (gamepadEnabledOobe &&
                        ev.keyCode == WinJS.Utilities.Key.GamepadB) {
                        CloudExperienceHostAPI.AppEventNotificationManager.notifyBack();
                        return true;
                    }

                    return true; // Tells Knockout to allow the default action
                }
                element.addEventListener("keyup", enterKeyUpHandler);
            }
        }
    };

    ko.bindingHandlers.oobePageActionGamepadA = {
        update: function (element, valueAccessor) {
            let defaultAction = ko.unwrap(valueAccessor());
            if (defaultAction) {
                let lastSelectedElement;
                function enterKeyDownHandler(ev) {
                    if (gamepadEnabledOobe && ev.keyCode == WinJS.Utilities.Key.GamepadA) {
                        lastSelectedElement = ev.target;
                    }
                    return true; // Tells Knockout to allow the default action
                }
                element.addEventListener("keydown", enterKeyDownHandler);
                function enterKeyUpHandler(ev) {
                    if (isPageActionAllowedWithGamepadA(ev, lastSelectedElement)) {
                        defaultAction();
                        return false;
                    }

                    return true; // Tells Knockout to allow the default action
                }
                element.addEventListener("keyup", enterKeyUpHandler);
            }
        }
    };

    ko.bindingHandlers.iframeContent = {
        update: function (element, valueAccessor, allBindings) {
            let value = ko.utils.unwrapObservable(valueAccessor());
            if (value.content && value.dir) {
                let iFrameDocument = element.contentWindow.document;

                if (value.preventLinkNavigation) {
                    function loadHandler(event) {
                        if (!event.srcElement.initialLoadComplete) {
                            event.srcElement.initialLoadComplete = true;
                        }
                        else if (event.srcElement.needReload) {
                            KnockoutHelpers.loadIframeContent(element, event.srcElement.contentWindow.document, value);
                            event.srcElement.needReload = false;
                        }
                        else {
                            event.srcElement.needReload = true; // allow next load to complete
                            event.srcElement.src = "about:blank";
                        }
                        return true; // Tells Knockout to allow the default action
                    }
                    element.addEventListener("load", loadHandler);
                }
                KnockoutHelpers.loadIframeContent(element, iFrameDocument, value);
            }
        }
    };

    return KnockoutHelpers;
});
