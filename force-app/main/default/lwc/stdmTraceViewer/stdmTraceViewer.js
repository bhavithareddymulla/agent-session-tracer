import { LightningElement, track, api, wire } from 'lwc';
import getCompleteSessionTrace from '@salesforce/apex/StdmResearchService.getCompleteSessionTrace';
import { subscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import STDM_SESSION_CHANNEL from '@salesforce/messageChannel/StdmSessionChannel__c';

export default class StdmTraceViewer extends LightningElement {
    @track _sessionId = '';
    @track sessionData = null;
    @track error = null;
    @track isLoading = false;
    @track expandedSteps = new Set();
    @track expandedInteractions = new Set();
    @track showMessageModal = false;
    @track selectedMessage = null;
    @track actionsOnlyFilter = new Map();

    subscription = null;

    @wire(MessageContext)
    messageContext;

    @api
    get sessionId() {
        return this._sessionId;
    }
    set sessionId(value) {
        this._sessionId = value;
        if (value) {
            this.handleSearch();
        }
    }

    connectedCallback() {
        this.subscribeToMessageChannel();
    }

    subscribeToMessageChannel() {
        if (!this.subscription) {
            this.subscription = subscribe(
                this.messageContext,
                STDM_SESSION_CHANNEL,
                (message) => this.handleSessionSelection(message),
                { scope: APPLICATION_SCOPE }
            );
        }
    }

    handleSessionSelection(message) {
        if (message.sessionId) {
            this._sessionId = message.sessionId;
            this.handleSearch();
        }
    }

    get hasSessionData() {
        return this.sessionData !== null;
    }

    // --- Health stats ---

    get healthPct() {
        return this.sessionData?.health?.healthPct ?? 0;
    }

    get healthTotal() {
        return this.sessionData?.health?.totalInteractions ?? 0;
    }

    get healthActual() {
        return this.sessionData?.health?.actualRecords ?? 0;
    }

    get healthReconstructed() {
        return this.sessionData?.health?.reconstructed ?? 0;
    }

    get healthMissingOutput() {
        return this.sessionData?.health?.missingOutputCount ?? 0;
    }

    get hasMissingOutputs() {
        return this.healthMissingOutput > 0;
    }

    get healthBannerClass() {
        const pct = this.healthPct;
        if (pct >= 80) return 'health-banner health-banner-good';
        if (pct >= 50) return 'health-banner health-banner-warning';
        return 'health-banner health-banner-critical';
    }

    // --- Session metadata ---

    get sessionMetadata() {
        if (!this.sessionData?.session) return [];
        const s = this.sessionData.session;
        return [
            { label: 'Session ID', value: s.sessionId || 'N/A' },
            { label: 'Channel Type', value: s.channelType || 'N/A' },
            { label: 'Start Time', value: this.formatDateTime(s.startTime) },
            { label: 'End Time', value: this.formatDateTime(s.endTime) },
            { label: 'Duration', value: this.formatDuration(s.elapsedTimeMs) },
            { label: 'Messaging Session', value: s.messagingSessionId || 'N/A' }
        ];
    }

    // --- Interactions with steps ---

    get interactionsWithSteps() {
        if (!this.sessionData?.interactions) return [];

        return this.sessionData.interactions.map((interaction, index) => {
            const isExpanded = this.expandedInteractions.has(interaction.interactionId);

            const messages = this.sessionData.messages
                ? this.sessionData.messages
                    .filter(msg => msg.interactionId === interaction.interactionId)
                    .map(msg => {
                        const contentText = msg.contentText || '';
                        const isLong = contentText.length > 200 || contentText.split('\n').length > 2;
                        const preview = isLong
                            ? contentText.split('\n').slice(0, 2).join('\n').substring(0, 200) + '...'
                            : contentText;

                        return {
                            ...msg,
                            sentTimeFormatted: this.formatDateTime(msg.sentTimestamp),
                            messageIcon: msg.messageType === 'Input' ? 'utility:user' : 'utility:bot',
                            bubbleClass: msg.messageType === 'Input' ? 'message-bubble-input' : 'message-bubble-output',
                            isLong,
                            preview,
                            fullText: contentText,
                            interactionId: interaction.interactionId
                        };
                    })
                : [];

            const showActionsOnly = this.actionsOnlyFilter.get(interaction.interactionId) || false;

            const steps = this.sessionData.steps
                .filter(step => {
                    if (step.interactionId !== interaction.interactionId) return false;
                    if (showActionsOnly) return step.stepType === 'ACTION_STEP';
                    return true;
                })
                .map(step => {
                    const stepExpanded = this.expandedSteps.has(step.stepId);
                    const isActionStep = step.stepType === 'ACTION_STEP';

                    let actionDetails = null;
                    if (isActionStep) {
                        actionDetails = this.parseActionStep(step);
                    }

                    return {
                        ...step,
                        isExpanded: stepExpanded,
                        chevronIcon: stepExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                        durationFormatted: this.formatDuration(step.elapsedTimeMs),
                        startTimeFormatted: this.formatDateTime(step.startTime),
                        endTimeFormatted: this.formatDateTime(step.endTime),
                        stepTypeClass: this.getStepTypeClass(step.stepType),
                        stepTypeLabel: this.formatStepType(step.stepType),
                        hasInput: !!(step.inputValueText && step.inputValueText.length > 0),
                        hasOutput: !!(step.outputValueText && step.outputValueText.length > 0),
                        hasError: !!(step.errorMessage && step.errorMessage.length > 0 && step.errorMessage != 'NOT_SET'),
                        isActionStep,
                        actionDetails
                    };
                });

            const allSteps = this.sessionData.steps.filter(s => s.interactionId === interaction.interactionId);
            const actionStepCount = allSteps.filter(s => s.stepType === 'ACTION_STEP').length;

            return {
                ...interaction,
                index: index + 1,
                isExpanded,
                chevronIcon: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                durationFormatted: this.formatDuration(interaction.elapsedTimeMs),
                interactionTypeBadge: 'interaction-type-badge',
                messages,
                messageCount: messages.length,
                hasMessages: messages.length > 0,
                steps,
                stepCount: steps.length,
                actionStepCount,
                hasActions: actionStepCount > 0,
                filterButtonVariant: showActionsOnly ? 'brand' : 'border-filled'
            };
        });
    }

    // --- Event handlers ---

    handleSessionIdChange(event) {
        this._sessionId = event.target.value;
        this.error = null;
    }

    handleKeyPress(event) {
        if (event.key === 'Enter') {
            this.handleSearch();
        }
    }

    async handleSearch() {
        if (!this._sessionId.trim()) {
            this.error = 'Please enter a Session ID';
            return;
        }

        this.isLoading = true;
        this.error = null;
        this.sessionData = null;

        try {
            const result = await getCompleteSessionTrace({ sessionId: this._sessionId.trim() });
            this.sessionData = JSON.parse(result);
            this.expandedInteractions = new Set();
            this.expandedSteps = new Set();
            this.actionsOnlyFilter = new Map();
        } catch (error) {
            this.error = error.body?.message || 'An error occurred while fetching session data';
            console.error('Error fetching session trace:', error);
        } finally {
            this.isLoading = false;
        }
    }

    handleClear() {
        this._sessionId = '';
        this.sessionData = null;
        this.error = null;
        this.expandedSteps = new Set();
        this.expandedInteractions = new Set();
        this.actionsOnlyFilter = new Map();
    }

    toggleInteraction(event) {
        const interactionId = event.currentTarget.dataset.id;
        if (this.expandedInteractions.has(interactionId)) {
            this.expandedInteractions.delete(interactionId);
        } else {
            this.expandedInteractions.add(interactionId);
        }
        this.expandedInteractions = new Set(this.expandedInteractions);
    }

    toggleStep(event) {
        const stepId = event.currentTarget.dataset.id;
        if (this.expandedSteps.has(stepId)) {
            this.expandedSteps.delete(stepId);
        } else {
            this.expandedSteps.add(stepId);
        }
        this.expandedSteps = new Set(this.expandedSteps);
    }

    expandAllInteractions() {
        if (!this.sessionData?.interactions) return;
        this.expandedInteractions = new Set(
            this.sessionData.interactions.map(i => i.interactionId)
        );
    }

    collapseAllInteractions() {
        this.expandedInteractions = new Set();
    }

    toggleActionsFilter(event) {
        event.stopPropagation();
        const interactionId = event.currentTarget.dataset.interactionId;
        const currentValue = this.actionsOnlyFilter.get(interactionId) || false;
        this.actionsOnlyFilter.set(interactionId, !currentValue);
        this.actionsOnlyFilter = new Map(this.actionsOnlyFilter);
    }

    showFullMessage(event) {
        event.stopPropagation();
        const messageId = event.currentTarget.dataset.messageId;
        const interactionId = event.currentTarget.dataset.interactionId;

        const interaction = this.interactionsWithSteps.find(i => i.interactionId === interactionId);
        if (interaction) {
            const message = interaction.messages.find(m => m.messageId === messageId);
            if (message) {
                this.selectedMessage = {
                    ...message,
                    modalTitle: `${message.messageType} Message - ${message.sentTimeFormatted}`
                };
                this.showMessageModal = true;
            }
        }
    }

    closeMessageModal() {
        this.showMessageModal = false;
        this.selectedMessage = null;
    }

    handleExport() {
        if (!this.sessionData) return;
        const dataStr = JSON.stringify(this.sessionData, null, 2);
        const blob = new Blob([dataStr], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `session-trace-${this._sessionId}.json`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    // --- Action step parsing ---

    parseActionStep(step) {
        const details = {
            actionName: step.name || 'Unknown Action',
            apiInfo: null
        };

        try {
            if (step.outputValueText) {
                const outputJson = JSON.parse(step.outputValueText);
                if (outputJson.output) {
                    const output = outputJson.output;
                    if (output.statusCode || output.statusDescription) {
                        details.apiInfo = {
                            statusCode: output.statusCode || 'N/A',
                            statusDescription: output.statusDescription || 'N/A'
                        };
                    }
                }
            }
        } catch (e) {
            // non-JSON output, skip
        }

        return details;
    }

    // --- Formatters ---

    formatDateTime(dateTimeStr) {
        if (!dateTimeStr) return 'N/A';
        try {
            return new Date(dateTimeStr).toLocaleString('en-US', {
                year: 'numeric',
                month: 'short',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                fractionalSecondDigits: 3
            });
        } catch (e) {
            return dateTimeStr;
        }
    }

    formatDuration(milliseconds) {
        if (milliseconds == null) return 'N/A';
        if (milliseconds < 1000) return `${milliseconds}ms`;
        if (milliseconds < 60000) return `${(milliseconds / 1000).toFixed(2)}s`;
        const minutes = Math.floor(milliseconds / 60000);
        const seconds = ((milliseconds % 60000) / 1000).toFixed(2);
        return `${minutes}m ${seconds}s`;
    }

    formatStepType(stepType) {
        if (!stepType) return 'Unknown';
        return stepType.replace(/_/g, ' ').toLowerCase()
            .split(' ')
            .map(word => word.charAt(0).toUpperCase() + word.slice(1))
            .join(' ');
    }

    getStepTypeClass(stepType) {
        const typeMap = {
            'LLM_STEP': 'step-type-llm',
            'ACTION_STEP': 'step-type-action',
            'TOOL_STEP': 'step-type-tool',
            'ROUTING_STEP': 'step-type-routing',
            'TOPIC_STEP': 'step-type-routing'
        };
        return typeMap[stepType] || 'step-type-default';
    }
}