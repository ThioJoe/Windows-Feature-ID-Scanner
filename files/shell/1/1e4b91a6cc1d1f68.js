
"use strict";

define([
    'autopilot/commercialDiagnosticsUtilities',
    'legacy/events',
    'legacy/bridge'], (
    commercialDiagnosticsUtilities,
    constants,
    bridge) => {
    class bootstrapStatusCategoryView {
        constructor(
            resourceStrings,
            sessionUtilities,
            parentTable,
            categoryViewModel) {


            this.CATEGORY_TITLE_ID = "categoryId";
            this.DETAILS_BUTTON_ID = "DETAILS_BUTTON_ID";
            this.CATEGORY_STATUS_ID = "CATEGORY_STATUS_ID";
            this.SUBCATEGORIES_SECTION_ID = "SUBCATEGORIES_SECTION_ID";
            this.PROGRESS_BAR_ID = "PROGRESS_BAR_ID";
            this.STATE_NAME_STATUS = "Status";
            this.FORCED_RESULT_SUCCESS = "FORCED_RESULT_SUCCESS";
            this.FORCED_RESULT_FAILURE = "FORCED_RESULT_FAILURE";

            this.SUBCATEGORY_PROPERTY_NAME_STATE = "subcategoryState";
            this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT = "subcategoryStatusText";

            this.CATEGORY_PROPERTY_NAME_STATE = "categoryState";
            this.CATEGORY_PROPERTY_NAME_STATUS_TEXT = "categoryStatusText";

            this.E_CANCELED = 0x800704C7;
            this.E_UNEXPECTED = 0x8000FFFF;

            this.MAX_WAIT_FOR_REBOOT_IN_MILLISECONDS = 60000; // 1 minute

            this.resourceStrings = resourceStrings;
            this.sessionUtilities = sessionUtilities;
            this.categoryViewModel = categoryViewModel;
            this.storedCategoryStatus = {};

            this.startOneActionBatchPromise = null;
            this.batchCancelled = false;
            this.commercialDiagnosticsUtilities = new commercialDiagnosticsUtilities();

            this.categoryBody = document.createElement("div");

            let categoryLabelRow = document.createElement("div");
            categoryLabelRow.className = "table-row";

            this.categoryLabelIconCell = document.createElement("div");
            this.categoryLabelIconCell.className = "table-cell glyph-cell-lite";
            this.categoryLabelIconCell.setAttribute("aria-hidden", true);

            let categoryLabelIconDiv = document.createElement("div");
            categoryLabelIconDiv.className = "glyph-lite";

            this.categoryLabelIconElement = document.createElement("span");
            this.categoryLabelIconElement.className = categoryViewModel.getIconClass() + " status-icon";

            categoryLabelIconDiv.appendChild(this.categoryLabelIconElement);
            this.categoryLabelIconCell.appendChild(categoryLabelIconDiv);
            categoryLabelRow.appendChild(this.categoryLabelIconCell);

            this.categoryLabelCell = document.createElement("div");
            this.categoryLabelCell.className = "table-cell";

            let categoryLabel = document.createElement("p");
            categoryLabel.className = "category-label-lite";
            categoryLabel.appendChild(document.createTextNode(categoryViewModel.getTitle()));

            this.categoryLabelCell.appendChild(categoryLabel);
            categoryLabelRow.appendChild(this.categoryLabelCell);

            this.chevronDetailsButtonCell = document.createElement("div");
            this.chevronDetailsButtonCell.className = "table-cell";

            this.chevronDetailsButtonElement = document.createElement("button");
            this.chevronDetailsButtonElement.id = this.DETAILS_BUTTON_ID;
            this.chevronDetailsButtonElement.className = "buttonCell-lite";
            this.chevronDetailsButtonElement.tabIndex = 0;
            this.chevronDetailsButtonElement.style.border = "none";
            this.chevronDetailsButtonElement.setAttribute("aria-expanded", "false");
            this.chevronDetailsButtonElement.setAttribute("aria-label", this.categoryViewModel.getTitle() + " " + resourceStrings["BootstrapPageShowDetailsButton"]);
            this.chevronDetailsButtonElement.addEventListener("click", this.handleClickEventOnDetailsButton.bind(this));

            this.chevron = document.createElement("span");
            this.chevron.className = "icon-chevron-down";

            this.chevronDetailsButtonElement.appendChild(this.chevron);
            this.chevronDetailsButtonCell.appendChild(this.chevronDetailsButtonElement);
            categoryLabelRow.appendChild(this.chevronDetailsButtonCell);
            this.categoryBody.appendChild(categoryLabelRow);

            let categoryStatusRow = document.createElement("div");
            categoryStatusRow.className = "table-row";

            let categoryStatusRowEmptyCell = document.createElement("div");
            categoryStatusRowEmptyCell.className = "table-cell";
            categoryStatusRow.appendChild(categoryStatusRowEmptyCell);

            this.categoryStatusIconCell = document.createElement("div");
            this.categoryStatusIconCell.className = "table-cell";
            this.categoryStatusIconCell.colSpan = "2";

            let categoryStatusText = this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATUS_TEXT);

            if (undefined === categoryStatusText) {
                categoryStatusText = resourceStrings["BootstrapPageStatusWaitingForPrevious"];
            }

            this.statusIconBackground = document.createElement("span");
            this.statusIconBackground.className = "status-icon-padding glyph-lite base-lite icon-fill success-lite";
            this.sessionUtilities.hideElement(this.statusIconBackground, false);
            this.categoryStatusIconCell.appendChild(this.statusIconBackground);

            this.statusIconGlyph = document.createElement("span");
            this.statusIconGlyph.className = "status-icon-padding glyph-lite overlay-lite icon-checkmark-lite";
            this.sessionUtilities.hideElement(this.statusIconGlyph, false);
            this.categoryStatusIconCell.appendChild(this.statusIconGlyph);

            this.categoryStatusElement = document.createElement("span");
            this.categoryStatusElement.id = this.CATEGORY_STATUS_ID;
            this.categoryStatusElement.className = "status-lite";
            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, categoryStatusText);
            this.categoryStatusIconCell.appendChild(this.categoryStatusElement);

            categoryStatusRow.appendChild(this.categoryStatusIconCell);
            this.categoryBody.appendChild(categoryStatusRow);

            this.progressAnimationRow  = document.createElement("div");
            this.progressAnimationRow .className = "table-row";

            let progressAnimationRowEmptyCell = document.createElement("div");
            progressAnimationRowEmptyCell.className = "table-cell";
            this.progressAnimationRow.appendChild(progressAnimationRowEmptyCell);

            this.progressAnimationCell = document.createElement("div");
            this.progressAnimationCell.className = "table-cell";

            this.categoryProgressBarElement = document.createElement("progress");
            this.categoryProgressBarElement.id = this.PROGRESS_BAR_ID;
            this.categoryProgressBarElement.className = "win-progress-bar";
            this.progressAnimationCell.appendChild(this.categoryProgressBarElement);
            this.sessionUtilities.hideElement(this.progressAnimationRow, false);

            this.progressAnimationRow.appendChild(this.progressAnimationCell);
            this.categoryBody.appendChild(this.progressAnimationRow);

            let subcategoriesRow = document.createElement("div");
            subcategoriesRow.className = "table-row";

            let subcategoriesRowEmptyCell = document.createElement("div");
            subcategoriesRowEmptyCell.className = "table-cell";
            subcategoriesRow.appendChild(subcategoriesRowEmptyCell);

            this.subcategoriesCell = document.createElement("div");
            this.subcategoriesCell.className = "table-cell";

            this.subcategoriesSectionElement = document.createElement("div");
            this.subcategoriesSectionElement.id = this.SUBCATEGORIES_SECTION_ID;
            this.sessionUtilities.hideElement(this.subcategoriesSectionElement, true);

            this.bootstrapSubcategories = categoryViewModel.getSubcategories();

            this.initializationPromise = this.getStoredCategoryStatusAsync().then((categoryStatus) => {
                this.storedCategoryStatus = categoryStatus;

                if (undefined === this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE)) {
                    let newCategoryProperties = {};
                    newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_NOT_STARTED;

                    return this.setCategoryPropertiesAsync(newCategoryProperties);
                }
            }).then(() => {
                for (let i = 0; i < this.bootstrapSubcategories.length; i++) {
                    let currentSubcategory = this.bootstrapSubcategories[i];

                    if (undefined === this.getSubcategoryProperty(
                        currentSubcategory.getId(),
                        this.SUBCATEGORY_PROPERTY_NAME_STATE)) {

                        let newSubcategoryProperties = {};
                        newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.SUBCATEGORY_STATE_NOT_STARTED;

                        this.setSubcategoryPropertiesAsync(currentSubcategory.getId(), newSubcategoryProperties);
                    }

                    let subcategoryDisposition = currentSubcategory.getDisposition();

                    if (subcategoryDisposition === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                        let subcategoryText = this.getSubcategoryProperty(
                            currentSubcategory.getId(),
                            this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT);

                        if (undefined === subcategoryText) {
                            subcategoryText = this.commercialDiagnosticsUtilities.formatMessage(
                                resourceStrings["BootstrapPageSubcategoryTextTemplate"],
                                currentSubcategory.getTitle(),
                                resourceStrings["BootstrapPageStatusWaitingForPrevious"]);
                        }

                        let subcategoryLabel = document.createElement("p");
                        subcategoryLabel.className = "subcategory-label-lite";
                        this.sessionUtilities.replaceNodeText(subcategoryLabel, subcategoryText);
                        currentSubcategory.setUiElement(subcategoryLabel);
                        this.subcategoriesSectionElement.appendChild(subcategoryLabel);
                    }
                }

                this.subcategoriesSectionElement.appendChild(document.createElement("br"));

                this.subcategoriesCell.appendChild(this.subcategoriesSectionElement);
                subcategoriesRow.appendChild(this.subcategoriesCell);
                this.categoryBody.appendChild(subcategoriesRow);

                return categoryViewModel.getInitializationPromise();
            });
        }


        handleClickEventOnDetailsButton() {
            if (this.sessionUtilities.isElementHidden(this.subcategoriesSectionElement)) {
                this.sessionUtilities.showElement(this.subcategoriesSectionElement, true);
                this.chevronDetailsButtonElement.setAttribute("aria-expanded", "true");
                this.chevron.className = "icon-chevron-up";
            } else {
                this.sessionUtilities.hideElement(this.subcategoriesSectionElement, true);
                this.chevronDetailsButtonElement.setAttribute("aria-expanded", "false");
                this.chevron.className = "icon-chevron-down";
            }
        }

        async updateSubcategoryTextFromActionResultsAsync(subcategory, actionResults) {
            let subcategoryText = actionResults.actionResultState;

            this.commercialDiagnosticsUtilities.logInfoEvent(
                this.sessionUtilities.subcategorySucceeded(actionResults.actionResultState) ?
                    "CommercialOOBE_BootstrapStatusCategory_SubcategoryProcessing_Success" :
                    "CommercialOOBE_BootstrapStatusCategory_SubcategoryProcessing_Failed",
                `BootstrapStatus: Subcategory ID = ${subcategory.getId()}; state = ${actionResults.actionResultState}.`);

            if (subcategory.getDisposition() === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                let statusText = null;

                if ((actionResults.statusMessage !== null) && (actionResults.statusMessage !== undefined)) {
                    statusText = actionResults.statusMessage;

                } else if (actionResults.actionResultState === this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED) {
                    statusText = this.resourceStrings["BootstrapPageStatusComplete"];

                } else if (actionResults.actionResultState === this.sessionUtilities.SUBCATEGORY_STATE_REBOOT_REQUIRED_AND_TRY_AGAIN) {
                    statusText = this.resourceStrings["BootstrapPageStatusRebootRequired"];

                } else {
                    statusText = this.resourceStrings["BootstrapPageStatusFailed"];
                }

                subcategoryText = this.commercialDiagnosticsUtilities.formatMessage(
                    this.resourceStrings["BootstrapPageSubcategoryTextTemplate"],
                    subcategory.getTitle(),
                    statusText);

                this.sessionUtilities.replaceNodeText(subcategory.getUiElement(), subcategoryText);
            }

            let newSubcategoryProperties = {};
            newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT] = subcategoryText;

            await this.setSubcategoryPropertiesAsync(subcategory.getId(), newSubcategoryProperties);
        }

        async startOneActionBatchAsync(previousActionSucceeded, useParallelizableActions, forcedResult, tryingAgain) {
            if (this.currentSubcategoryIndex >= this.bootstrapSubcategories.length) {
                return previousActionSucceeded;
            }

            let subcategoriesToExecute = [];
            for (; this.currentSubcategoryIndex < this.bootstrapSubcategories.length; this.currentSubcategoryIndex++) {
                let currentSubcategory = this.bootstrapSubcategories[this.currentSubcategoryIndex];
                let currentSubcategoryId = currentSubcategory.getId();

                if (useParallelizableActions !== currentSubcategory.isParallelizableAction()) {
                    break;
                } else if (!useParallelizableActions && (subcategoriesToExecute.length === 1)) {
                    break;
                }
                
                let subcategoryDisposition = currentSubcategory.getDisposition();

                if (subcategoryDisposition !== this.sessionUtilities.SUBCATEGORY_DISPOSITION_IGNORED) {
                    let resultText;

                    if (!this.shouldRunSubcategory(currentSubcategoryId, tryingAgain)) {
                        resultText = this.getSubcategoryProperty(
                            currentSubcategoryId,
                            this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT);
                    }

                    if ((undefined === resultText) && (forcedResult !== null)) {
                        switch (forcedResult) {
                            case this.FORCED_RESULT_SUCCESS:
                                resultText = this.resourceStrings["BootstrapPageStatusComplete"];
                                break;

                            case this.FORCED_RESULT_FAILURE:
                                resultText = this.resourceStrings["BootstrapPageStatusFailed"];
                                break;
                        }
                    }

                    if (resultText !== undefined) {
                        if (subcategoryDisposition === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                            this.sessionUtilities.replaceNodeText(
                                currentSubcategory.getUiElement(),
                                resultText);
                        }
                    }

                    if (this.shouldRunSubcategory(currentSubcategoryId, tryingAgain)) {
                        subcategoriesToExecute.push(currentSubcategory);
                    }
                }
            }
            
            if (0 === subcategoriesToExecute.length) {
                return await this.startOneActionBatchAsync(previousActionSucceeded, !useParallelizableActions, forcedResult, tryingAgain);
            }
            
            this.commercialDiagnosticsUtilities.logInfoEvent(
                "CommercialOOBE_BootstrapStatusCategory_BatchProcessing_Started",
                `BootstrapStatus: Processing one ${useParallelizableActions ? "parallelizable" : "non-parallelizable"} batch of ${subcategoriesToExecute.length} subcategories...`);

            for (let i = 0; i < subcategoriesToExecute.length; i++) {
                let currentSubcategory = subcategoriesToExecute[i];
                let subcategoryDisposition = currentSubcategory.getDisposition();
                let subcategoryState;
                let statusText;

                if (previousActionSucceeded) {
                    statusText = this.resourceStrings["BootstrapPageStatusWorking"];
                    subcategoryState = this.sessionUtilities.SUBCATEGORY_STATE_IN_PROGRESS;
                } else {
                    statusText = this.resourceStrings["BootstrapPageStatusPreviousStepFailed"];
                    subcategoryState = this.sessionUtilities.SUBCATEGORY_STATE_FAILED_FROM_PREVIOUS_SUBCATEGORY;
                }

                let subcategoryText = this.commercialDiagnosticsUtilities.formatMessage(
                    this.resourceStrings["BootstrapPageSubcategoryTextTemplate"],
                    currentSubcategory.getTitle(),
                    statusText);

                if (subcategoryDisposition === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                    this.sessionUtilities.replaceNodeText(currentSubcategory.getUiElement(), subcategoryText);
                }

                let newSubcategoryProperties = {};
                newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATE] = subcategoryState;
                newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT] = subcategoryText;

                await this.setSubcategoryPropertiesAsync(currentSubcategory.getId(), newSubcategoryProperties);
            }

            if (!previousActionSucceeded) {
                return await this.startOneActionBatchAsync(previousActionSucceeded, !useParallelizableActions, forcedResult, tryingAgain);
            }

            this.batchCancelled = false;
            let actionsToWaitOn = [];
            let subcategoryTextTemplate = this.resourceStrings["BootstrapPageSubcategoryTextTemplate"];
            for (let i = 0; i < subcategoriesToExecute.length; i++) {
                let currentSubcategory = subcategoriesToExecute[i];
                let title = currentSubcategory.getTitle();
                let uiElement = currentSubcategory.getUiElement();

                let progressCallbackAsync = (progressText) => {
                    if (!this.batchCancelled) {
                        let subcategoryDisposition = currentSubcategory.getDisposition();

                        if (subcategoryDisposition === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                            let finalMessage = this.commercialDiagnosticsUtilities.formatMessage(subcategoryTextTemplate, title, progressText);

                            this.sessionUtilities.replaceNodeText(uiElement, finalMessage);

                            let newSubcategoryProperties = {};
                            newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT] = finalMessage;

                            return this.setSubcategoryPropertiesAsync(currentSubcategory.getId(), newSubcategoryProperties);
                        }
                    }

                    return WinJS.Promise.as(true);
                };

                let setSubcategoryStateCallbackAsync = (newSubcategoryState) => {
                    let newSubcategoryProperties = {};
                    newSubcategoryProperties[this.SUBCATEGORY_PROPERTY_NAME_STATE] = newSubcategoryState;

                    return this.setSubcategoryPropertiesAsync(currentSubcategory.getId(), newSubcategoryProperties);
                };

                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_BootstrapStatusCategory_SubcategoryProcessing_Started",
                    this.commercialDiagnosticsUtilities.formatMessage("BootstrapStatus: Starting subcategory {0}...", subcategoriesToExecute[i].getId()));

                actionsToWaitOn.push(subcategoriesToExecute[i].startActionAsync(progressCallbackAsync, setSubcategoryStateCallbackAsync));
            }

            await WinJS.Promise.join(actionsToWaitOn);

            let batchSucceeded = true;
            let batchRequiresReboot = false;

            for (let i = 0; i < subcategoriesToExecute.length; i++) {
                let currentSubcategory = subcategoriesToExecute[i];
                let actionResult = currentSubcategory.getActionResult();

                await this.updateSubcategoryTextFromActionResultsAsync(currentSubcategory, actionResult);
                    
                if (!this.sessionUtilities.subcategorySucceeded(actionResult.actionResultState)) {
                    if (this.subcategoryNeedsReboot(actionResult.actionResultState)) {
                        batchRequiresReboot = true;

                        this.commercialDiagnosticsUtilities.logInfoEvent(
                            "CommercialOOBE_ESP_Subcategory_RebootRequiredBySubcategory_" + currentSubcategory.getId(),
                            `BootstrapStatus: Reboot required by subcategory ${currentSubcategory.getId()}.`);
                    } else {
                        batchSucceeded = false;
                    }
                }
            }

            let maxWaitForRebootInMilliseconds = 0;

            if (batchSucceeded && batchRequiresReboot) {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_BootstrapStatusCategory_RebootCoalescing_Initiated",
                    `BootstrapStatus: ${useParallelizableActions ? "Parallelizable" : "Non-parallelizable"} batch of ${subcategoriesToExecute.length} subcategories requires a reboot.`);

                bridge.invoke("CloudExperienceHost.AutoPilot.EnrollmentStatusPage.setStatusPageReboot");

                try {
                    maxWaitForRebootInMilliseconds = this.MAX_WAIT_FOR_REBOOT_IN_MILLISECONDS;

                    bridge.fireEvent(constants.Events.done, constants.AppResult.action1);
                } catch (e) {
                    this.commercialDiagnosticsUtilities.logExceptionEvent(
                        "CommercialOOBE_BootstrapStatusCategory_Rebooting_NavigationFailed",
                        "BootstrapStatus: Navigation to reboot failed.",
                        e);

                    batchSucceeded = false;

                    batchRequiresReboot = false;
                    maxWaitForRebootInMilliseconds = 0;
                }
            } else {
                this.commercialDiagnosticsUtilities.logInfoEvent(
                    batchSucceeded ? "CommercialOOBE_BootstrapStatusCategory_BatchProcessing_Success" : "CommercialOOBE_BootstrapStatusCategory_BatchProcessing_Failed",
                    `BootstrapStatus: ${useParallelizableActions ? "Parallelizable" : "Non-parallelizable"} batch of ${subcategoriesToExecute.length} subcategories ${batchSucceeded ? "succeeded" : "failed"}`);
            }

            await WinJS.Promise.timeout(maxWaitForRebootInMilliseconds);

            if (batchRequiresReboot) {
                batchSucceeded = false;

                this.commercialDiagnosticsUtilities.logHresultEvent(
                    "CommercialOOBE_BootstrapStatusCategory_Rebooting_TimedOut",
                    "BootstrapStatus: Device failed to reboot within allotted time.",
                    this.E_UNEXPECTED);
            }

            if (!batchSucceeded) {
                this.sessionUtilities.enrollmentApis.updateServerWithResult(false, this.sessionUtilities.runningInOobe());

                this.commercialDiagnosticsUtilities.logInfoEvent(
                    "CommercialOOBE_BootstrapStatusCategory_SendingFailureResultToMdmServer",
                    `BootstrapStatus: ${this.getId()} category sent failure result to MDM server.`);
            }

            return await this.startOneActionBatchAsync(batchSucceeded, !useParallelizableActions, forcedResult, tryingAgain);
        }

        getCategoryStatusId() {
            return this.categoryViewModel.getId() + "." + this.STATE_NAME_STATUS;
        }

        getStoredCategoryStatusAsync() {
            return this.sessionUtilities.getSettingAsync(this.getCategoryStatusId()).then((categoryStatusValue) => {
                if ((categoryStatusValue !== null) && (categoryStatusValue.length > 0)) {
                    return WinJS.Promise.as(JSON.parse(categoryStatusValue));
                }

                return WinJS.Promise.as({});
            });
        }

        storeCategoryStatusAsync() {
            if (this.storedCategoryStatus !== null) {
                let categoryStatusValue = JSON.stringify(this.storedCategoryStatus);

                return this.sessionUtilities.storeSettingAsync(this.getCategoryStatusId(), categoryStatusValue);
            }

            return WinJS.Promise.as(false);
        }

        getCategoryProperty(propertyName) {
            return this.storedCategoryStatus[propertyName];
        }

        async setCategoryPropertiesAsync(propertyBag) {
            for (const propertyName in propertyBag) {
                this.storedCategoryStatus[propertyName] = propertyBag[propertyName];
            }

            await this.storeCategoryStatusAsync();
        }

        getSubcategoryProperty(subcategoryId, propertyName) {
            if (this.storedCategoryStatus[subcategoryId] === undefined) {
                this.storedCategoryStatus[subcategoryId] = {};
            }

            return this.storedCategoryStatus[subcategoryId][propertyName];
        }

        async setSubcategoryPropertiesAsync(subcategoryId, propertyBag) {
            if (this.storedCategoryStatus[subcategoryId] === undefined) {
                this.storedCategoryStatus[subcategoryId] = {};
            }

            for (const propertyName in propertyBag) {
                this.storedCategoryStatus[subcategoryId][propertyName] = propertyBag[propertyName];
            }

            await this.storeCategoryStatusAsync();
        }

        subcategoryNeedsReboot(subcategoryState) {
            return (subcategoryState === this.sessionUtilities.SUBCATEGORY_STATE_REBOOT_REQUIRED_AND_TRY_AGAIN);
        }

        isSubcategoryInTerminalState(subcategoryState) {
            return ((subcategoryState === this.sessionUtilities.SUBCATEGORY_STATE_SUCCEEDED) ||
                (subcategoryState === this.sessionUtilities.SUBCATEGORY_STATE_FAILED) ||
                (subcategoryState === this.sessionUtilities.SUBCATEGORY_STATE_CANCELLED) ||
                (subcategoryState === this.sessionUtilities.SUBCATEGORY_STATE_FAILED_FROM_PREVIOUS_SUBCATEGORY));
        }

        shouldRunCategory(tryingAgain) {
            return (!this.isCategoryInTerminalState() ||
                (tryingAgain && !this.sessionUtilities.categorySucceeded(this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE))));
        }

        shouldRunSubcategory(subcategoryId, tryingAgain) {
            let subcategoryState = this.getSubcategoryProperty(subcategoryId, this.SUBCATEGORY_PROPERTY_NAME_STATE);

            return (!this.isSubcategoryInTerminalState(subcategoryState) ||
                (tryingAgain && !this.sessionUtilities.subcategorySucceeded(subcategoryState)));
        }

        categoryStateHidesSubcategories(categoryState) {
            return ((categoryState === this.sessionUtilities.CATEGORY_STATE_NOT_STARTED) ||
                (categoryState === this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY));
        }

        setSuccessVisuals(message) {
            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, message);
            this.categoryStatusElement.className = "status-lite";
            this.categoryStatusElement.style.opacity = "";

            this.statusIconBackground.className = "status-icon-padding glyph-lite base-lite icon-fill success-lite";
            this.statusIconGlyph.className = "status-icon-padding glyph-lite overlay-lite icon-checkmark-lite";

            this.sessionUtilities.showElement(this.statusIconBackground, false);
            this.sessionUtilities.showElement(this.statusIconGlyph, false);
        }

        setFailureVisuals(message) {
            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, message);
            this.categoryStatusElement.className = "status-lite";
            this.categoryStatusElement.style.opacity = 1;

            this.statusIconBackground.className = "status-icon-padding glyph-lite base-lite icon-fill failure-lite";
            this.statusIconGlyph.className = "status-icon-padding glyph-lite overlay-lite icon-exmark-lite";

            this.sessionUtilities.showElement(this.statusIconBackground, false);
            this.sessionUtilities.showElement(this.statusIconGlyph, false);
        }

        resetVisuals() {
            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, this.resourceStrings["BootstrapPageStatusWaitingForPrevious"]);
            this.categoryStatusElement.className = "status-lite";
            this.categoryStatusElement.style.opacity = "";

            this.sessionUtilities.hideElement(this.statusIconBackground, false);
            this.sessionUtilities.hideElement(this.statusIconGlyph, false);
        }

        restoreCategoryStatus() {
            let categoryState = this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE);
            let categoryStatusText = this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATUS_TEXT);

            if (this.sessionUtilities.categorySucceeded(categoryState)) {
                this.setSuccessVisuals(categoryStatusText);
            } else if (categoryState === this.sessionUtilities.CATEGORY_STATE_FAILED) {
                this.setFailureVisuals(categoryStatusText);
            } else {
                this.sessionUtilities.replaceNodeText(this.categoryStatusElement, categoryStatusText);
                this.categoryStatusElement.className = "status-lite";
            }

            if (!this.categoryStateHidesSubcategories(categoryState)) {
                this.sessionUtilities.showElement(this.chevronDetailsButtonElement, false);

                for (let i = 0; i < this.bootstrapSubcategories.length; i++) {
                    let currentSubcategory = this.bootstrapSubcategories[i];
                    let currentSubcategoryId = currentSubcategory.getId();
                    let currentSubcategoryStatusText = this.getSubcategoryProperty(currentSubcategoryId, this.SUBCATEGORY_PROPERTY_NAME_STATUS_TEXT);

                    if (currentSubcategory.getDisposition() === this.sessionUtilities.SUBCATEGORY_DISPOSITION_VISIBLE) {
                        if (currentSubcategoryStatusText === undefined) {
                            currentSubcategoryStatusText = this.resourceStrings["BootstrapPageStatusNoSetupNeeded"];
                        }

                        this.sessionUtilities.replaceNodeText(currentSubcategory.getUiElement(), currentSubcategoryStatusText);
                    }
                }
            }
        }


        getId() {
            return this.categoryViewModel.getId();
        }

        getDisposition() {
            return this.categoryViewModel.getDisposition();
        }

        runsInOobe() {
            return this.categoryViewModel.runsInOobe();
        }

        getInitializationPromise() {
            return this.initializationPromise;
        }

        getClickHandler() {
            return this.categoryViewModel.getClickHandler();
        }

        getCategoryBody() {
            return this.categoryBody;
        }

        isCategoryInTerminalState() {
            let categoryState = this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE);

            return ((categoryState === this.sessionUtilities.CATEGORY_STATE_SUCCEEDED) ||
                (categoryState === this.sessionUtilities.CATEGORY_STATE_FAILED) ||
                (categoryState === this.sessionUtilities.CATEGORY_STATE_CANCELLED) ||
                (categoryState === this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY));
        }

        async showPreviousStepFailedStatusTextIfApplicableAsync() {
            if (!this.isCategoryInTerminalState()) {
                let newCategoryProperties = {};
                newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY;

                await this.setCategoryPropertiesAsync(newCategoryProperties);

                this.sessionUtilities.replaceNodeText(this.categoryStatusElement, this.resourceStrings["BootstrapPageStatusPreviousStepFailed"]);
                this.categoryStatusElement.className = "status-lite";
            }
        }

        async prepareForContinueAnywayAsync() {
            let categoryState = this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE);

            if (categoryState == this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY) {
                let newCategoryProperties = {};
                newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_NOT_STARTED;

                await this.setCategoryPropertiesAsync(newCategoryProperties);
            }
        }

        async resetForTryAgainAsync() {
            switch (this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE)) {
                case this.sessionUtilities.CATEGORY_STATE_FAILED:
                case this.sessionUtilities.CATEGORY_STATE_CANCELLED:
                case this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY:
                    let statusMessage = this.resourceStrings["BootstrapPageStatusWaitingForPrevious"];

                    this.sessionUtilities.replaceNodeText(this.categoryStatusElement, statusMessage);
                    this.categoryStatusElement.className = "status-lite";

                    let newCategoryProperties = {};
                    newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_NOT_STARTED;
                    newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATUS_TEXT] = statusMessage;

                    await this.setCategoryPropertiesAsync(newCategoryProperties);
                    break;
            }

            return;
        }

        async startActionsAsync(previousCategorySucceeded, tryingAgain) {
            if (!this.shouldRunCategory(tryingAgain)) {
                this.restoreCategoryStatus();
                return WinJS.Promise.as(this.sessionUtilities.categorySucceeded(this.getCategoryProperty(this.CATEGORY_PROPERTY_NAME_STATE)));
            }

            this.resetVisuals();

            if (!previousCategorySucceeded) {
                let newCategoryProperties = {};
                newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_FAILED_FROM_PREVIOUS_CATEGORY;
                newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATUS_TEXT] = this.resourceStrings["BootstrapPageStatusPreviousStepFailed"];

                this.sessionUtilities.replaceNodeText(this.categoryStatusElement, this.resourceStrings["BootstrapPageStatusPreviousStepFailed"]);
                this.categoryStatusElement.className = "status-lite";

                await this.setCategoryPropertiesAsync(newCategoryProperties);

                return WinJS.Promise.as(previousCategorySucceeded);
            } else {
                return new WinJS.Promise((completeDispatch, errorDispatch, progressDispatch) => {

                    let newCategoryProperties = {};
                    newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_IN_PROGRESS;

                    return this.setCategoryPropertiesAsync(newCategoryProperties).then(() => {
                        let forcedResult = null;

                        if (!this.sessionUtilities.runningInOobe() &&
                            this.runsInOobe()) {
                            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, this.resourceStrings["BootstrapPageStatusComplete"]);
                            this.categoryStatusElement.className = "status-lite";

                            forcedResult = this.FORCED_RESULT_SUCCESS;
                        } else {
                            this.sessionUtilities.showElement(this.progressAnimationRow, false);

                            this.sessionUtilities.replaceNodeText(this.categoryStatusElement, this.resourceStrings["BootstrapPageStatusWorking"]);
                            this.categoryStatusElement.className = "status-lite";
                        }

                        this.sessionUtilities.showElement(this.chevronDetailsButtonElement, false);

                        this.currentSubcategoryIndex = 0;

                        this.startOneActionBatchPromise = this.startOneActionBatchAsync(true, true, forcedResult, tryingAgain);

                        return this.startOneActionBatchPromise;
                    }).then((actionSucceeded) => {
                        let categoryStatusMessage = null;
                        let categoryState = null;

                        this.sessionUtilities.hideElement(this.progressAnimationRow, false);

                        if (actionSucceeded) {
                            categoryState = this.sessionUtilities.CATEGORY_STATE_SUCCEEDED;
                            categoryStatusMessage = this.resourceStrings["BootstrapPageStatusComplete"];
                            this.setSuccessVisuals(categoryStatusMessage);
                        } else {
                            categoryState = this.sessionUtilities.CATEGORY_STATE_FAILED;
                            categoryStatusMessage = this.resourceStrings["BootstrapPageStatusFailed"];
                            this.setFailureVisuals(categoryStatusMessage);
                        }

                        newCategoryProperties = {};
                        newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = categoryState;
                        newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATUS_TEXT] = categoryStatusMessage;

                        return this.setCategoryPropertiesAsync(newCategoryProperties).then(() => {
                            return actionSucceeded;
                        });
                    }).then((actionSucceeded) => {
                        completeDispatch(actionSucceeded);
                    }, (error) => {
                        this.commercialDiagnosticsUtilities.logExceptionEvent(
                            "CommercialOOBE_BootstrapStatusCategory_StartOneAction_Failed",
                            "BootstrapStatus: startOneActionBatchPromise failed",
                            error);
                    });
                },
                () => {
                    this.commercialDiagnosticsUtilities.logHresultEvent(
                        "CommercialOOBE_BootstrapStatusCategory_StartActions_Cancelled",
                        "BootstrapStatus: startActionsAsync is cancelled.",
                        this.E_CANCELED);
                    this.batchCancelled = true;

                    if (this.startOneActionBatchPromise !== null) {
                        this.startOneActionBatchPromise.cancel();
                    }

                    let newCategoryProperties = {};
                    newCategoryProperties[this.CATEGORY_PROPERTY_NAME_STATE] = this.sessionUtilities.CATEGORY_STATE_CANCELLED;

                    return this.setCategoryPropertiesAsync(newCategoryProperties);
                });
            }
        }
    }

    return bootstrapStatusCategoryView;
});
