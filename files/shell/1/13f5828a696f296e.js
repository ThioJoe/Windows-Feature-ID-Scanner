//
// Copyright (C) Microsoft. All rights reserved.
//
define(['lib/knockout', 'legacy/bridge', 'legacy/events',
    'optional!sample/Sample.CloudExperienceHostAPI.Speech.SpeechSynthesis'], (ko, bridge, eventConstants) => {
        // Provide no-op for WV2
        const Debug = (typeof self.Debug !== 'undefined') ? self.Debug : { assert: () => { }, break: () => { } };

        let pendingPanelTransition = WinJS.Promise.as(null);

        let componentLoadCompleteCallback;
        let componentLoadingPromise = new WinJS.Promise((reportComplete) => {
        componentLoadCompleteCallback = reportComplete;
    });
    let pendingComponentLoads = 0;
    let initialComponentLoadComplete = false;
    function onComponentPreloaded(component) {
        if (!initialComponentLoadComplete && --pendingComponentLoads == 0) {
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

    // Assume keyboard as the default/starting key input modality, except on gamepad-based devices.
    let currentKeyInputModality = "keyboard";

    requireAsync(['legacy/bridge']).then((result) => {
        return result.legacy_bridge.invoke("CloudExperienceHost.getContext");
    }).then((targetContext) => {
        if (parseInt(targetContext.deviceForm) === 46 /* DEVICEFAMILYDEVICEFORM_GAMING_HANDHELD */) {
            currentKeyInputModality = "gamepad";
        }
    });

    // Register a keydown handler, on the document root, in the capture phase so elements can use this information when they eventually handle events.
    document.addEventListener("keydown", (ev) => {
        let oldModality = currentKeyInputModality;

        const gamepadKeys = [
            "GamepadA", "GamepadB", "GamepadX", "GamepadY",
            "GamepadLeftShoulder", "GamepadRightShoulder",
            "GamepadLeftTrigger", "GamepadRightTrigger",
            "GamepadDPadUp", "GamepadDPadDown", "GamepadDPadLeft", "GamepadDPadRight",
            "GamepadMenu", "GamepadView", "GamepadLeftThumbstick", "GamepadRightThumbstick",
            "GamepadLeftThumbstickUp", "GamepadLeftThumbstickDown", "GamepadLeftThumbstickRight", "GamepadLeftThumbstickLeft",
            "GamepadRightThumbstickUp", "GamepadRightThumbstickDown", "GamepadRightThumbstickRight", "GamepadRightThumbstickLeft"
        ];

        if (gamepadKeys.includes(ev.key)) {
            currentKeyInputModality = "gamepad";
        }
        else {
            currentKeyInputModality = "keyboard";
        }

        if (oldModality !== currentKeyInputModality) {
            document.dispatchEvent(new Event("keyInputModalityChanged"))
        }
    }, { capture: true });

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
        if (ev.keyCode == WinJS.Utilities.Key.GamepadA && ev.target == lastSelectedElement) {
            let isLink = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "a");
            let isButton = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "button");
            let isSelect = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "select");
            let isInput = ev.target && ev.target.tagName && (ev.target.tagName.toLowerCase() === "input");
            if (!isLink && !isButton && !isSelect && !isInput) {
                return true;
            }
        }
        return false;
    }

    class KnockoutHelpers {
        // Register components
        registerComponents(scenarioMode) {
            if (componentsRegistered) { Debug.break(); return; }

            // Components to register and pre-load
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
                'oobe-toggle': {},
                'oobe-listview': {},
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

            let components = componentsLookupTable[scenarioMode].components;

            // Setup naming convention and path for templates and view models for requirejs to load
            let componentLoader = {
                getConfig: (name, callback) => {
                    let viewModelConfig = { require: componentsLookupTable[scenarioMode].viewModelConfigPath + name + '-vm' };
                    let templateConfig = { require: 'lib/text!' + componentsLookupTable[scenarioMode].templateConfigPth + name + '-template.html' };
                    // The synchronous flag means components are *allowed* to load synchronously,
                    // after the initial load which is always async
                    callback({ viewModel: viewModelConfig, template: templateConfig, synchronous: true });
                },
                loadViewModel: (name, viewModelConfig, callback) => {
                    // Pass the component root element to the VM,
                    // and hook up an easy way to get to the VM from the element
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

            // Register virtual elements
            Object.keys(components).forEach((key) => {
                ko.components.register(key, components[key]);
            });

            // Preload async components and allow waiting on them
            Object.keys(components).forEach((key) => {
                pendingComponentLoads++;
                ko.components.get(key, onComponentPreloaded);
            });

            componentsRegistered = true;
        }

        static registerDialogComponents() {
            if (dialogComponentsRegistered) { Debug.break(); return; }

            let customDialogComponents = {
                'oobe-retaildemo-dialog': {},
                'oobe-retaildemo-exit-dialog': {},
            };

            // Register virtual elements
            Object.keys(customDialogComponents).forEach((key) => {
                ko.components.register(key, customDialogComponents[key]);
            });

            // Preload async components and allow waiting on them
            Object.keys(customDialogComponents).forEach((key) => {
                dialogPendingComponentLoads++;
                ko.components.get(key, onDialogComponentPreloaded);
            });

            dialogComponentsRegistered = true;
        }

        // Since we don't have jQuery with its handy .index() method...
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
            // Enable winjs control binding
            require(['lib/knockout-winjs'], callback);
        }

        static setFocusOnAutofocusElement() {
            let currentPanel = document.querySelector('.current-visible-panel');
            // If there is no current panel, assume the page does not use panels and see if there is an autofocus element in the doc
            let autofocusElement = currentPanel ? currentPanel.querySelector("[autofocus='true']") : document.querySelector("[autofocus='true']");
            let firstInput = currentPanel ? currentPanel.querySelector("input") : null;
            if (autofocusElement) {
                autofocusElement.focus();
            } else if (firstInput) {
                firstInput.focus();
            }
        }

        static showErrorContent(iFrameElement, errorMessage, dirVal, frameTitleVal) {
            let cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";
            let innerHTML = `<html><head><link href="${cssOverride}" rel="stylesheet"></head>`;
            innerHTML += "<body><p>" + errorMessage + "</p></body></html>";
            let doc = iFrameElement.contentWindow.document;
            doc.body.innerHTML = innerHTML;
            this.loadIframeContent(iFrameElement, doc, { dir: dirVal, frameTitle: frameTitleVal });
        }

        static showLearnMoreContent(iFrameElement, href, dirVal, isInternetAvailable, errorMessage, frameTitleVal, anchorId) {
            if (isInternetAvailable) {
                let url = href + "&profile=transparentLight";
                fetch(url)
                    .then(response => {
                        if (!response.ok) throw new Error('Network response was not ok');
                        return response.text();
                    })
                    .then(html => {
                        let doc = iFrameElement.contentWindow.document;
                        doc.body.innerHTML = html;

                        let fileRef = doc.head.ownerDocument.createElement("link");
                        let cssOverride = "/webapps/inclusiveOobe/css/light-iframe-content.css";
                        fileRef.setAttribute("rel", "stylesheet");
                        fileRef.setAttribute("href", cssOverride);

                        if (anchorId) {
                            fileRef.onload = function () {
                                let anchor = doc.getElementById(anchorId);
                                if (anchor) {
                                    anchor.scrollIntoView();
                                }
                            }
                        }
                        doc.head.appendChild(fileRef);
                    })
                    .catch(error => {
                        this.showErrorContent(iFrameElement, errorMessage, dirVal, frameTitleVal);
                    });
            }
            else {
                this.showErrorContent(iFrameElement, errorMessage, dirVal, frameTitleVal);
            }
        }

        static loadIframeContent(iFrameElement, iFrameDocument, value) {
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
            // Set the initial tabIndex based on the current input modality
            updateTabIndexBasedOnInputModality();
            document.addEventListener("keyInputModalityChanged", updateTabIndexBasedOnInputModality);

            iFrameDocument.dir = value.dir;
            iFrameDocument.body.setAttribute("tabindex", "0");

            if (value.focusBody) {
                if (currentKeyInputModality === "gamepad") {
                    iFrameElement.focus();
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

            iFrameDocument.title = value.frameTitle;
            iFrameElement.title = value.frameTitle;

            let setPseudoFocus = () => {
                iFrameElement.classList.add("pseudo-focused");
                iFrameDocument.body.classList.add("pseudo-focused");
                // Set the gamepad legend display override for B button
                bridge.invoke("CloudExperienceHost.StringResources.makeResourceObject", "resources").done((result) => {
                    let resourceStrings = JSON.parse(result);
                    bridge.invoke("CloudExperienceHost.AppFrame.setGamepadLegendDisplayOverrideForB", resourceStrings.GamepadButtonDeselect);
                });
            };

            let removePseudoFocus = () => {
                iFrameElement.classList.remove("pseudo-focused");
                iFrameDocument.body.classList.remove("pseudo-focused");

                bridge.invoke("CloudExperienceHost.AppFrame.setGamepadLegendDisplayOverrideForB", "");
            };

            // Register keydown/up listeners on the <iframe /> itself to be able to handle:
            // - `enter` invoking pageDefaultAction
            // - `GamepadA` "capturing" focus within this iFrame
            let lastObservedTarget;
            iFrameElement.addEventListener("keydown", (ev) => {
                switch (ev.key) {
                    // Capture the target element on keyDown so we can check in keyUp if focus may have moved
                    // between the two events (which is possible if another key is pressed down before this one is raised).
                    case "Enter":
                    case "GamepadA":
                        lastObservedTarget = ev.target;
                        break;

                    default:
                        break;
                }
                return true; // Tells Knockout to allow the default action
            });

            iFrameElement.addEventListener("keyup", (ev) => {
                let handled = false;

                switch (ev.key) {
                    case "Enter":
                        if (isPageDefaultActionAllowed(ev, lastObservedTarget)) {
                            defaultAction();//value.pageDefaultAction();
                            handled = true;
                        }
                        break;

                    case "GamepadA":
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

            // Register keydown/up listeners on the root document within the iFrame to be able to handle:
            // - `enter` invoking pageDefaultAction
            // - `GamepadB` "releasing" captured focus from this iFrame
            // - `GamepadDPad*` and `GamepadLeftThumbstick*` scrolling the contents of the iFrame
            // - `Gamepad*Trigger` approximating PageUp/PageDown scrolling of the iFrame
            let lastObservedTargetWithinIFrame;
            iFrameDocument.addEventListener("keydown", (ev) => {
                let handled = false;
                let goingUpOrLeft = false;

                switch (ev.key) {
                    // Capture the target element on keyDown so we can check in keyUp if focus may have moved
                    // between the two events (which is possible if another key is pressed down before this one is raised).
                    case "Enter":
                    case "GamepadB":
                        lastObservedTargetWithinIFrame = ev.target;
                        break;

                    // Approximate what a PageUp/PageDown would scroll
                    case "GamepadLeftTrigger":
                        goingUpOrLeft = true;
                    case "GamepadRightTrigger":
                        if (iFrameElement.classList.contains("pseudo-focused")) {
                            iFrameDocument.body.scrollTop += (goingUpOrLeft ? -0.87 : 0.87) * iFrameDocument.defaultView.innerHeight;
                            handled = true;
                        }
                        break;

                    // Approximate what an Up/Down arrow key would scroll
                    case "GamepadDPadUp":
                    case "GamepadLeftThumbstickUp":
                        goingUpOrLeft = true;
                    case "GamepadDPadDown":
                    case "GamepadLeftThumbstickDown":
                        if (iFrameElement.classList.contains("pseudo-focused")) {
                            iFrameDocument.body.scrollTop += (goingUpOrLeft ? -0.13 : 0.13) * iFrameDocument.defaultView.innerHeight;
                            handled = true;
                        }
                        break;

                    // Approximate what an Left/Right arrow key would scroll
                    case "GamepadDPadLeft":
                    case "GamepadLeftThumbstickLeft":
                        goingUpOrLeft = true;
                    case "GamepadDPadRight":
                    case "GamepadLeftThumbstickRight":
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

                switch (ev.key) {
                    case "Enter":
                        if (isPageDefaultActionAllowed(ev, lastObservedTargetWithinIFrame)) {
                            defaultAction();//value.pageDefaultAction();
                            handled = true;
                        }
                        break;

                    case "GamepadB":
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
                // This function (update) gets called for every panel when the active panel index changes.
                // Each panel decides whether it should be hidden or shown.
                // The setImmediate here ensures the hidden panel starts its exit animation (and assigns to pendingPanelTransition)
                // before the entrance animation gets queued by the incoming panel.
                // This introduces a very small timing window where two panels can have entrance animations queued in setImmediate callbacks
                // We synchronously add this class to the chosen incoming panel (and remove from others) to guard against this.
                element.classList.add("current-visible-panel");
                setImmediate(() => {
                    // Ensure we don't queue an entrance if another panel got selected as visible before the setImmediate callback fired
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
                                    // If there is no item with the autofocus attribute then fall back to setting focus on the first input element
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
                bridge.invoke("CloudExperienceHost.FeatureStaging.tryGetIsFeatureEnabled", "OobeLimitCortanaVoiceover")
                    .then((objFeatureEnabled) => {
                        let isOobeLimitCortanaVoiceoverEnabled = objFeatureEnabled.result ? objFeatureEnabled.value : false;
                        let useVoiceOver = isOobeLimitCortanaVoiceoverEnabled ? (viewModel.hasOwnProperty("useVoiceOver") && viewModel.useVoiceOver) : true;

                        speechSynthesis.speakAsync(valueUnwrapped, useVoiceOver).done(() => {
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

                    if (ev.key === "GamepadB") {
                        bridge.fireEvent(eventConstants.Events.backButtonClicked)
                        return false;
                    }

                    return true; // Tells Knockout to allow the default action
                }
                element.addEventListener("keyup", enterKeyUpHandler);
            }
        }
    };

    ko.bindingHandlers.useGamepadForDefaultActions = {
        // The expectation for using this binding is that it is evaluated once right at the page's initial load
        // and is not updated afterwards. It also expects that a defaultAction is bound to the same element, and that
        // this is not an observable type (meaning it also won't change during runtime).
        init: function (element, valueAccessor, allBindings) {
            let allow = ko.unwrap(valueAccessor());
            let defaultAction = allBindings.get("oobePageDefaultAction");

            if ((allow === true) && defaultAction) {
                let lastObservedElementForA;
                let lastObservedElementForB;

                element.addEventListener("keydown", (ev) => {
                    switch (ev.key) {
                        case "GamepadA":
                            lastObservedElementForA = ev.target;
                            break;

                        case "GamepadB":
                            lastObservedElementForB = ev.target;
                            break;

                        default:
                            break;
                    }
                    return true; // Tells Knockout to allow the default action
                });

                element.addEventListener("keyup", (ev) => {
                    let handled = true;

                    if (isPageActionAllowedWithGamepadA(ev, lastObservedElementForA)) {
                        defaultAction();
                    }
                    else if ((ev.key === "GamepadB") && (ev.target === lastObservedElementForB)) {
                        bridge.fireEvent(eventConstants.Events.backButtonClicked)
                    }
                    else {
                        handled = false;
                    }

                    return !handled;
                });
            }
        }
    };

    ko.bindingHandlers.iframeContent = {
        update: function (element, valueAccessor, allBindings) {
            let value = ko.utils.unwrapObservable(valueAccessor());
            if (value.dir) {
                KnockoutHelpers.loadIframeContent(element, element.contentWindow.document, value);
            }
        }
    };

        return KnockoutHelpers;
    });
