import { LightningElement, track, wire } from 'lwc';
import getAgentList from '@salesforce/apex/StdmResearchService.getAgentList';
import getSessionsByAgent from '@salesforce/apex/StdmResearchService.getSessionsByAgent';
import { publish, MessageContext } from 'lightning/messageService';
import STDM_SESSION_CHANNEL from '@salesforce/messageChannel/StdmSessionChannel__c';

export default class StdmSessionBrowser extends LightningElement {
    @track selectedAgent = '';
    @track startDate = '';
    @track endDate = '';
    @track sessions = [];
    @track error = null;
    @track isLoading = false;

    agentOptions = [];

    @wire(MessageContext)
    messageContext;

    @wire(getAgentList)
    wiredAgents({ error, data }) {
        if (data) {
            this.agentOptions = data;
        } else if (error) {
            this.error = 'Error loading agents: ' + (error.body?.message || error.message);
        }
    }

    get hasSessions() {
        return this.sessions && this.sessions.length > 0;
    }

    get sessionCount() {
        return this.sessions ? this.sessions.length : 0;
    }

    get tableColumns() {
        return [
            {
                label: 'Session ID',
                fieldName: 'sessionId',
                type: 'text',
                cellAttributes: { class: 'session-id-cell' }
            },
            {
                label: 'Start Time',
                fieldName: 'startTimeFormatted',
                type: 'text'
            },
            {
                label: 'Duration',
                fieldName: 'durationFormatted',
                type: 'text'
            },
            {
                label: 'Channel',
                fieldName: 'channelType',
                type: 'text'
            },
            {
                label: '',
                type: 'button',
                typeAttributes: {
                    label: 'Trace',
                    name: 'view_trace',
                    variant: 'brand'
                }
            }
        ];
    }

    handleAgentChange(event) {
        this.selectedAgent = event.detail.value;
    }

    handleStartDateChange(event) {
        this.startDate = event.target.value;
    }

    handleEndDateChange(event) {
        this.endDate = event.target.value;
    }

    async handleSearch() {
        if (!this.selectedAgent) {
            this.error = 'Please select an agent';
            return;
        }

        this.isLoading = true;
        this.error = null;
        this.sessions = [];

        try {
            const result = await getSessionsByAgent({
                agentApiName: this.selectedAgent,
                startDate: this.startDate || null,
                endDate: this.endDate || null
            });

            this.sessions = result.map(session => ({
                ...session,
                startTimeFormatted: this.formatDateTime(session.startTime),
                durationFormatted: this.formatDuration(session.elapsedTimeMs)
            }));

            if (this.sessions.length === 0) {
                this.error = 'No sessions found for the selected criteria';
            }
        } catch (error) {
            this.error = 'Error: ' + (error.body?.message || error.message);
        } finally {
            this.isLoading = false;
        }
    }

    handleRowAction(event) {
        const row = event.detail.row;
        publish(this.messageContext, STDM_SESSION_CHANNEL, { sessionId: row.sessionId });
    }

    handleClear() {
        this.selectedAgent = '';
        this.startDate = '';
        this.endDate = '';
        this.sessions = [];
        this.error = null;
    }

    formatDateTime(dateTimeStr) {
        if (!dateTimeStr) return 'N/A';
        try {
            return new Date(dateTimeStr).toLocaleString('en-US', {
                year: 'numeric', month: 'short', day: 'numeric',
                hour: '2-digit', minute: '2-digit', second: '2-digit'
            });
        } catch (e) {
            return dateTimeStr;
        }
    }

    formatDuration(ms) {
        if (ms == null) return 'N/A';
        if (ms < 1000) return `${ms}ms`;
        if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`;
        const minutes = Math.floor(ms / 60000);
        const seconds = ((ms % 60000) / 1000).toFixed(2);
        return `${minutes}m ${seconds}s`;
    }
}