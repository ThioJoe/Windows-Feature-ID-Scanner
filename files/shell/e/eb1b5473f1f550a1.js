define(["legacy/bridge"], (bridge) => {
    class OobeToggleViewModel {
        constructor(params, element) {
            this.titleText = ko.isObservable(params.titleText) ? params.titleText : ko.observable(params.titleText);
            this.labelOnText = params.labelOnText;
            this.labelOffText = params.labelOffText;
            this.checkedValue = ko.isObservable(params.checked) ? params.checked : ko.observable(params.checked);
            this.contentHeader = params.contentHeader || null;
            this.descriptionOn = params.descriptionOn || this.titleText();
            this.descriptionOff = params.descriptionOff || this.titleText();
            this.summaryFormatString = params.summaryFormatString;
            this.isLastInAGroupValue = ko.isObservable(params.isLastInAGroup) ? params.isLastInAGroup : ko.observable(params.isLastInAGroup);
            this.currentAccDescription = ko.pureComputed(() => {
                let isChecked = this.checkedValue();
                let description = isChecked ? this.descriptionOn : this.descriptionOff;
                let sliderAt = isChecked ? this.labelOnText : this.labelOffText;
                return this.summaryFormatString.replace("%1", description).replace("%2", sliderAt);
            });
            
            this.checkedValue.subscribe(() => {
                const title = this.titleText();
                this.titleText(" ");
                this.titleText(title);
            });

            this.element = element;
            this.clickHandler = this.onClick.bind(this);
            element.addEventListener("click", this.clickHandler);
            element.addEventListener("pointerdown", this.onPointerDown, true /*useCapture*/ );

            this.keydownHandler = this.onKeyDown.bind(this);
            bridge.invoke("CloudExperienceHost.FeatureStaging.isOobeFeatureEnabled", "DisableToggleOnArrowKeys").done(function (result) {
                if (result) {
                    this.element.addEventListener("keydown", this.keydownHandler, true /*useCapture*/);
                }
            }.bind(this));
        }

        onKeyDown(ev) {
            const arrowKeys = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"];
            if (arrowKeys.includes(ev.key)) {
                ev.stopImmediatePropagation();
            }
        }

        onClick(ev) {
            this.checkedValue(!this.checkedValue());
            ev.preventDefault();
        }

        onPointerDown(ev) {
            ev.stopImmediatePropagation();
        }

        dispose() {
            this.element.removeEventListener("click", this.clickHandler);
            this.element.removeEventListener("pointerdown", this.onPointerDown);
            this.element.removeEventListener("keydown", this.keydownHandler);
        }
    }
    return OobeToggleViewModel;
});
