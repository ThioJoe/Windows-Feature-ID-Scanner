define(() => {
    class OobeListViewModel {
        constructor(params, element) {
            this.element = element;
            this.listContainer = element.querySelector(".scroll-view");
            this.listRootElement = element.querySelector(".list");
            this.items = params.items;
            this.itemLangValues = params.itemLangValues;
            this.listAccessibleName = params.listAccessibleName;
            this.selectionFollowsFocus = (params.selectionFollowsFocus === undefined) ? true : params.selectionFollowsFocus;
            this.isBinaryChoice = (params.binaryChoice === undefined) ? false : params.binaryChoice;
            this.selectedItem = params.selectedItem;
            this.selectedItem.subscribe(this.focusSelectedItem.bind(this));
            this.onItemKeyDown = this.handleKeyNav.bind(this);
            this.onItemKeyUp = this.handleKeyUpNav.bind(this);
            this.focusSelectedItem();
            this.ensuredInCenter = false;
            this.alwaysShowScrollbar = (params.alwaysShowScrollbar === undefined) ? false : params.alwaysShowScrollbar;
            this.searchQuery = ko.observable('');
            this.searchTimeout = null;
            this.isKeyPressEnabled = false;
            this.initializeTypeaheadEnabled();
            this.initializeGamepadEnabled();
            if (element.hasAttribute("autofocus")) {
                this.listRootElement.setAttribute("autofocus", true);
                element.removeAttribute("autofocus");
            }

            if (this.isBinaryChoice) {
                this.optInBinaryChoice();
            }

            if (this.alwaysShowScrollbar) {
                this.optInAlwaysShowScrollbar();
            }
        }

        initializeTypeaheadEnabled() {
            let featureEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("OobeListViewKeyPressSearch");
            if (featureEnabledObj.result && featureEnabledObj.value) { // feature found and enabled
                this.isKeyPressEnabled = featureEnabledObj.result;
            }
        }

        initializeGamepadEnabled() {
            let gamepadEnabledObj = CloudExperienceHostAPI.FeatureStaging.tryGetIsFeatureEnabled("GamepadEnabledOobe");
            this.gamepadEnabled = gamepadEnabledObj.result && gamepadEnabledObj.value;
        }

        optInBinaryChoice() {
            let el = this.listRootElement;
            el.className += " binaryChoice";
        }

        optInAlwaysShowScrollbar() {
            let el = this.listContainer;
            el.className += " alwaysShowScrollbar";
        }

        focusSelectedItem() {
            setImmediate(() => {
                let focusElement = this.listRootElement.querySelector(".list-item.selected");
                if (focusElement) {
                    focusElement.focus();

                    if (!this.ensuredInCenter) {
                        let targetoffset = focusElement.offsetTop;
                        let scrollView = this.element.querySelector(".scroll-view");
                        let contentboxHeight = scrollView.offsetHeight;
                        if (targetoffset > contentboxHeight) {
                            scrollView.scrollTop = targetoffset - contentboxHeight / 2;
                        }
                        this.ensuredInCenter = true;
                    }
                }
            });
        }

        onListFocus(list, e) {
            if (e.relatedTarget && e.relatedTarget.parentElement == this.listRootElement) {
                return;
            }
            let focusElement = this.listRootElement.querySelector(".list-item.selected") || e.target.firstElementChild;
            if (focusElement && focusElement.focus) {
                focusElement.focus();
                e.preventDefault();
            } 
        }
        
        onListFocusIn() {
            this.listRootElement.tabIndex = -1;
        }

        onListFocusOut(list, e) {
            let newFocusElement = e.relatedTarget;
            let isNewFocusListOrChild = newFocusElement &&
                                        ((newFocusElement == this.listRootElement) ||
                                        (newFocusElement.parentElement && (newFocusElement.parentElement == this.listRootElement)));
            if (!isNewFocusListOrChild) {
                this.listRootElement.tabIndex = 0;
            }
        }

        handlePageKey(goingUp, currentElement, scrollView) {
            let elementToFocus = currentElement;
            let itemHeight = currentElement.offsetHeight;
            if (itemHeight) {
                let itemsOnScreen = scrollView.offsetHeight / itemHeight;
                for (let i = 0; i < itemsOnScreen && (goingUp ? elementToFocus.previousElementSibling : elementToFocus.nextElementSibling); i++) {
                    elementToFocus = goingUp ? elementToFocus.previousElementSibling : elementToFocus.nextElementSibling;
                }
            }
            return elementToFocus;
        }

        handleKeyNav(item, e) {
            let currentElement = e.target;
            let scrollView = this.element.querySelector(".scroll-view");
            let elementToFocus = null;
            let goingUp = false;
            switch (e.keyCode) {
                case WinJS.Utilities.Key.GamepadDPadDown:
                case WinJS.Utilities.Key.GamepadLeftThumbstickDown:
                    if (this.gamepadEnabled) {
                        elementToFocus = currentElement.nextElementSibling;
                    }
                    break;
                case WinJS.Utilities.Key.downArrow:
                    elementToFocus = currentElement.nextElementSibling || currentElement;
                    break;
                case WinJS.Utilities.Key.GamepadDPadUp:
                case WinJS.Utilities.Key.GamepadLeftThumbstickUp:
                    if (this.gamepadEnabled) {
                        goingUp = true;
                        elementToFocus = currentElement.previousElementSibling;
                    }
                    break;
                case WinJS.Utilities.Key.upArrow:
                    goingUp = true;
                    elementToFocus = currentElement.previousElementSibling || currentElement;
                    break;
                case WinJS.Utilities.Key.home:
                    goingUp = true;
                    elementToFocus = this.listRootElement.firstElementChild;
                    break;
                case WinJS.Utilities.Key.end:
                    elementToFocus = this.listRootElement.lastElementChild;
                    break;
                case WinJS.Utilities.Key.GamepadLeftTrigger:
                    goingUp = true;
                case WinJS.Utilities.Key.GamepadRightTrigger:
                    if (this.gamepadEnabled) {
                        elementToFocus = this.handlePageKey(goingUp, currentElement, scrollView);
                    }
                    break;
                case WinJS.Utilities.Key.pageUp:
                    goingUp = true;
                case WinJS.Utilities.Key.pageDown:
                    elementToFocus = this.handlePageKey(goingUp, currentElement, scrollView);
                    break;
                case WinJS.Utilities.Key.space:
                    elementToFocus = currentElement;
                    if (!this.selectionFollowsFocus) {
                        this.selectedItem(ko.dataFor(currentElement));
                    }
                    break;
                case WinJS.Utilities.Key.enter:
                    if (!this.selectionFollowsFocus && (this.listRootElement.querySelector(".list-item.selected") !== currentElement)) {
                        elementToFocus = currentElement;
                    }
                    break;
                default :
                    if (this.isKeyPressEnabled === true) {
                        if (!this.isControlChar(e)) {
                            elementToFocus = this.handleContentKeydown(item, e);
                        }
                    }
            }

            if (elementToFocus) {
                let scrolled = false;
                if (elementToFocus.offsetTop < scrollView.scrollTop) {
                    scrolled = true;
                    scrollView.msZoomTo({
                        contentY: elementToFocus.offsetTop,
                        viewportY: "top",
                    });
                }
                else if ((elementToFocus.offsetTop + elementToFocus.offsetHeight) > (scrollView.scrollTop + scrollView.offsetHeight)) {
                    scrolled = true;
                    scrollView.msZoomTo({
                        contentY: (elementToFocus.offsetTop + elementToFocus.offsetHeight),
                        viewportY: "bottom",
                    });
                }
                setTimeout(() => {
                    elementToFocus.focus();
                }, scrolled ? 100 : 0);
                e.preventDefault();
                e.stopImmediatePropagation();
            }
            return true; // Tell KO not to mark everything handled
        }

        handleKeyUpNav(item, e) {
            let currentElement = e.target;
            switch (e.keyCode) {
                case WinJS.Utilities.Key.enter:
                    if (!this.selectionFollowsFocus) {
                        if (this.listRootElement.querySelector(".list-item.selected") !== currentElement) {
                            e.stopImmediatePropagation();
                        }
                        this.selectedItem(ko.dataFor(currentElement));
                    }
            }
        }

        isControlChar(event) {
            return (event.keyCode >= 0 && event.keyCode <= 31) || (event.keyCode === 127);
        }

        handleContentKeydown(item, event) {
            if (this.isKeyPressEnabled) {
                const key = event.key.toLowerCase();
                this.searchQuery(this.searchQuery() + key); // This is adding successive key presses to an ongoing query, with a 1000ms "reset".
                clearTimeout(this.searchTimeout);
                this.searchTimeout = setTimeout(() => {
                    this.searchQuery('');
                }, 1000);
                return this.searchAndHighlight(this.searchQuery());
            }
            return null;
        }

        searchAndHighlight(query) {
            if (this.isKeyPressEnabled) {
                const listElements = this.listRootElement.querySelectorAll('.list-item');
                let found = false;
                let elementToFocus = null;
                listElements.forEach(item => {
                    let header = item.querySelector('.listItemHeader');
                    if (header && header.textContent) {
                        const itemName = header.textContent.toLowerCase();
                        if (itemName.startsWith(query) && !found) {
                            found = true; // Stop after the first match
                            elementToFocus = item;
                        }
                    }
                });
                return elementToFocus;
            }
            return null;
        };
    }
    return OobeListViewModel;
});
