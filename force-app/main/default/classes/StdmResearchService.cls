public with sharing class StdmResearchService {

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAgentList() {
        try {
            List<SObject> participants = Database.query(
                'SELECT ssot__AiAgentApiName__c, ssot__AiAgentType__c ' +
                'FROM ssot__AIAgentSessionParticipant__dlm ' +
                'WHERE ssot__AiAgentSessionParticipantRole__c = \'AGENT\' ' +
                'AND ssot__AiAgentApiName__c != NULL ' +
                'AND ssot__AiAgentApiName__c != \'NOT_SET\' ' +
                'GROUP BY ssot__AiAgentApiName__c, ssot__AiAgentType__c ' +
                'ORDER BY ssot__AiAgentApiName__c ASC'
            );

            List<Map<String, String>> agentOptions = new List<Map<String, String>>();
            for (SObject participant : participants) {
                Map<String, String> option = new Map<String, String>();
                String agentApiName = (String)participant.get('ssot__AiAgentApiName__c');
                String agentType = (String)participant.get('ssot__AiAgentType__c');
                option.put('label', agentApiName + (agentType != null ? ' (' + agentType + ')' : ''));
                option.put('value', agentApiName);
                agentOptions.add(option);
            }
            return agentOptions;
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving agent list: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Map<String, Object>> getSessionsByAgent(
        String agentApiName, String startDate, String endDate
    ) {
        try {
            if (String.isBlank(agentApiName)) {
                throw new IllegalArgumentException('Agent API Name cannot be blank');
            }

            DateTime startDateTime = String.isNotBlank(startDate) ? DateTime.valueOf(startDate + ' 00:00:00') : null;
            DateTime endDateTime = String.isNotBlank(endDate) ? DateTime.valueOf(endDate + ' 23:59:59') : null;

            String participantQuery =
                'SELECT ssot__AiAgentSessionId__c, ssot__StartTimestamp__c ' +
                'FROM ssot__AIAgentSessionParticipant__dlm ' +
                'WHERE ssot__AiAgentApiName__c = :agentApiName ' +
                'AND ssot__AiAgentSessionParticipantRole__c = \'AGENT\' ';

            if (startDateTime != null) {
                participantQuery += 'AND ssot__StartTimestamp__c >= :startDateTime ';
            }
            if (endDateTime != null) {
                participantQuery += 'AND ssot__StartTimestamp__c <= :endDateTime ';
            }
            participantQuery += 'ORDER BY ssot__StartTimestamp__c DESC LIMIT 200';

            List<SObject> participants = Database.query(participantQuery);
            Set<String> sessionIds = new Set<String>();
            for (SObject p : participants) {
                String sid = (String)p.get('ssot__AiAgentSessionId__c');
                if (sid != null) sessionIds.add(sid);
            }

            if (sessionIds.isEmpty()) {
                return new List<Map<String, Object>>();
            }

            List<SObject> sessions = Database.query(
                'SELECT ssot__Id__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c, ' +
                '    ssot__AiAgentChannelType__c, ssot__AIAgentSessionEndType__c ' +
                'FROM ssot__AIAgentSession__dlm ' +
                'WHERE ssot__Id__c IN :sessionIds ' +
                'ORDER BY ssot__StartTimestamp__c DESC'
            );

            List<Map<String, Object>> sessionList = new List<Map<String, Object>>();
            for (SObject session : sessions) {
                Map<String, Object> sd = new Map<String, Object>();
                sd.put('sessionId', session.get('ssot__Id__c'));
                sd.put('startTime', session.get('ssot__StartTimestamp__c'));
                sd.put('endTime', session.get('ssot__EndTimestamp__c'));
                sd.put('channelType', session.get('ssot__AiAgentChannelType__c'));
                sd.put('endType', session.get('ssot__AIAgentSessionEndType__c'));

                DateTime st = (DateTime)session.get('ssot__StartTimestamp__c');
                DateTime et = (DateTime)session.get('ssot__EndTimestamp__c');
                if (st != null && et != null) {
                    sd.put('elapsedTimeMs', et.getTime() - st.getTime());
                }
                sessionList.add(sd);
            }
            return sessionList;
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving sessions: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String getCompleteSessionTrace(String sessionId) {
        try {
            if (String.isBlank(sessionId)) {
                throw new IllegalArgumentException('Session ID cannot be blank');
            }

            Map<String, Object> result = new Map<String, Object>();

            // 1. Session
            List<SObject> sessions = Database.query(
                'SELECT ssot__Id__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c, ' +
                '    ssot__RelatedMessagingSessionId__c, ssot__AiAgentChannelType__c, ' +
                '    ssot__AIAgentSessionEndType__c ' +
                'FROM ssot__AIAgentSession__dlm ' +
                'WHERE ssot__Id__c = :sessionId LIMIT 1'
            );

            if (sessions.isEmpty()) {
                throw new AuraHandledException('No session found with ID: ' + sessionId);
            }

            SObject session = sessions[0];
            Map<String, Object> sessionData = new Map<String, Object>();
            sessionData.put('sessionId', session.get('ssot__Id__c'));
            sessionData.put('startTime', session.get('ssot__StartTimestamp__c'));
            sessionData.put('endTime', session.get('ssot__EndTimestamp__c'));
            sessionData.put('messagingSessionId', session.get('ssot__RelatedMessagingSessionId__c'));
            sessionData.put('channelType', session.get('ssot__AiAgentChannelType__c'));
            sessionData.put('endType', session.get('ssot__AIAgentSessionEndType__c'));

            DateTime sessStart = (DateTime)session.get('ssot__StartTimestamp__c');
            DateTime sessEnd = (DateTime)session.get('ssot__EndTimestamp__c');
            if (sessStart != null && sessEnd != null) {
                sessionData.put('elapsedTimeMs', sessEnd.getTime() - sessStart.getTime());
            }
            result.put('session', sessionData);

            // 2. Messages — queried by sessionId (reliable)
            List<SObject> messages = Database.query(
                'SELECT ssot__Id__c, ssot__AiAgentInteractionId__c, ' +
                '    ssot__AiAgentInteractionMsgContentType__c, ' +
                '    ssot__AiAgentInteractionMessageType__c, ' +
                '    ssot__ContentText__c, ssot__MessageSentTimestamp__c, ' +
                '    ssot__AiAgentSessionParticipantId__c ' +
                'FROM ssot__AIAgentInteractionMessage__dlm ' +
                'WHERE ssot__AiAgentSessionId__c = :sessionId ' +
                'ORDER BY ssot__MessageSentTimestamp__c ASC'
            );

            // 3. Extract ALL interaction IDs from messages (the fix)
            Set<String> interactionIdsFromMessages = new Set<String>();
            for (SObject msg : messages) {
                String iid = (String)msg.get('ssot__AiAgentInteractionId__c');
                if (iid != null) interactionIdsFromMessages.add(iid);
            }

            // 4. Query actual Interaction records where they exist
            Map<String, SObject> interactionRecordMap = new Map<String, SObject>();
            if (!interactionIdsFromMessages.isEmpty()) {
                Set<String> iidsForQuery = interactionIdsFromMessages;
                List<SObject> interactionRecords = Database.query(
                    'SELECT ssot__Id__c, ssot__AiAgentInteractionType__c, ' +
                    '    ssot__TopicApiName__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c ' +
                    'FROM ssot__AIAgentInteraction__dlm ' +
                    'WHERE ssot__Id__c IN :iidsForQuery'
                );
                for (SObject ir : interactionRecords) {
                    interactionRecordMap.put((String)ir.get('ssot__Id__c'), ir);
                }
            }

            // 5. Query steps using message-derived interaction IDs (the fix)
            List<SObject> steps = new List<SObject>();
            if (!interactionIdsFromMessages.isEmpty()) {
                Set<String> iidsForQuery = interactionIdsFromMessages;
                steps = Database.query(
                    'SELECT ssot__Id__c, ssot__AiAgentInteractionId__c, ssot__Name__c, ' +
                    '    ssot__AiAgentInteractionStepType__c, ssot__StartTimestamp__c, ' +
                    '    ssot__EndTimestamp__c, ssot__InputValueText__c, ' +
                    '    ssot__OutputValueText__c, ssot__ErrorMessageText__c ' +
                    'FROM ssot__AIAgentInteractionStep__dlm ' +
                    'WHERE ssot__AiAgentInteractionId__c IN :iidsForQuery ' +
                    'ORDER BY ssot__StartTimestamp__c ASC'
                );
            }

            // 6. Build reconstructed interactions
            // Group messages and steps by interaction ID
            Map<String, List<SObject>> msgsByInteraction = new Map<String, List<SObject>>();
            for (SObject msg : messages) {
                String iid = (String)msg.get('ssot__AiAgentInteractionId__c');
                if (iid == null) continue;
                if (!msgsByInteraction.containsKey(iid)) {
                    msgsByInteraction.put(iid, new List<SObject>());
                }
                msgsByInteraction.get(iid).add(msg);
            }

            Map<String, List<SObject>> stepsByInteraction = new Map<String, List<SObject>>();
            for (SObject step : steps) {
                String iid = (String)step.get('ssot__AiAgentInteractionId__c');
                if (iid == null) continue;
                if (!stepsByInteraction.containsKey(iid)) {
                    stepsByInteraction.put(iid, new List<SObject>());
                }
                stepsByInteraction.get(iid).add(step);
            }

            // Build interaction list sorted by earliest timestamp
            Map<String, DateTime> interactionStartTimes = new Map<String, DateTime>();
            for (String iid : interactionIdsFromMessages) {
                DateTime earliest = null;
                if (msgsByInteraction.containsKey(iid)) {
                    for (SObject msg : msgsByInteraction.get(iid)) {
                        DateTime ts = (DateTime)msg.get('ssot__MessageSentTimestamp__c');
                        if (ts != null && (earliest == null || ts < earliest)) earliest = ts;
                    }
                }
                if (stepsByInteraction.containsKey(iid)) {
                    for (SObject step : stepsByInteraction.get(iid)) {
                        DateTime ts = (DateTime)step.get('ssot__StartTimestamp__c');
                        if (ts != null && (earliest == null || ts < earliest)) earliest = ts;
                    }
                }
                interactionStartTimes.put(iid, earliest);
            }

            // Sort interaction IDs by start time
            List<String> sortedIids = new List<String>(interactionIdsFromMessages);
            sortedIids.sort();
            // Simple sort by timestamp using a wrapper
            List<InteractionSortWrapper> sortWrappers = new List<InteractionSortWrapper>();
            for (String iid : sortedIids) {
                sortWrappers.add(new InteractionSortWrapper(iid, interactionStartTimes.get(iid)));
            }
            sortWrappers.sort();

            List<Map<String, Object>> interactionsList = new List<Map<String, Object>>();
            Integer actualRecordCount = 0;

            for (InteractionSortWrapper sw : sortWrappers) {
                String iid = sw.interactionId;
                Map<String, Object> interactionData = new Map<String, Object>();
                interactionData.put('interactionId', iid);

                Boolean hasActualRecord = interactionRecordMap.containsKey(iid);
                if (hasActualRecord) actualRecordCount++;
                interactionData.put('hasActualRecord', hasActualRecord);

                if (hasActualRecord) {
                    SObject ir = interactionRecordMap.get(iid);
                    interactionData.put('interactionType', ir.get('ssot__AiAgentInteractionType__c'));
                    interactionData.put('topicApiName', ir.get('ssot__TopicApiName__c'));
                    interactionData.put('startTime', ir.get('ssot__StartTimestamp__c'));
                    interactionData.put('endTime', ir.get('ssot__EndTimestamp__c'));

                    DateTime irSt = (DateTime)ir.get('ssot__StartTimestamp__c');
                    DateTime irEt = (DateTime)ir.get('ssot__EndTimestamp__c');
                    if (irSt != null && irEt != null) {
                        interactionData.put('elapsedTimeMs', irEt.getTime() - irSt.getTime());
                    }
                } else {
                    // Reconstruct from children
                    interactionData.put('interactionType', 'TURN');

                    // Derive topic from TOPIC_STEP
                    String derivedTopic = null;
                    if (stepsByInteraction.containsKey(iid)) {
                        for (SObject step : stepsByInteraction.get(iid)) {
                            if ('TOPIC_STEP' == (String)step.get('ssot__AiAgentInteractionStepType__c')) {
                                derivedTopic = (String)step.get('ssot__Name__c');
                                break;
                            }
                        }
                    }
                    interactionData.put('topicApiName', derivedTopic);

                    // Derive timestamps
                    DateTime earliest = null;
                    DateTime latest = null;
                    if (msgsByInteraction.containsKey(iid)) {
                        for (SObject msg : msgsByInteraction.get(iid)) {
                            DateTime ts = (DateTime)msg.get('ssot__MessageSentTimestamp__c');
                            if (ts != null) {
                                if (earliest == null || ts < earliest) earliest = ts;
                                if (latest == null || ts > latest) latest = ts;
                            }
                        }
                    }
                    if (stepsByInteraction.containsKey(iid)) {
                        for (SObject step : stepsByInteraction.get(iid)) {
                            DateTime stTs = (DateTime)step.get('ssot__StartTimestamp__c');
                            DateTime etTs = (DateTime)step.get('ssot__EndTimestamp__c');
                            if (stTs != null && (earliest == null || stTs < earliest)) earliest = stTs;
                            if (etTs != null && (latest == null || etTs > latest)) latest = etTs;
                        }
                    }
                    interactionData.put('startTime', earliest);
                    interactionData.put('endTime', latest);
                    if (earliest != null && latest != null) {
                        interactionData.put('elapsedTimeMs', latest.getTime() - earliest.getTime());
                    }
                }

                // Check for missing output messages
                Boolean hasInput = false;
                Boolean hasOutput = false;
                if (msgsByInteraction.containsKey(iid)) {
                    for (SObject msg : msgsByInteraction.get(iid)) {
                        String msgType = (String)msg.get('ssot__AiAgentInteractionMessageType__c');
                        if (msgType == 'Input') hasInput = true;
                        if (msgType == 'Output') hasOutput = true;
                    }
                }
                interactionData.put('hasInput', hasInput);
                interactionData.put('hasOutput', hasOutput);
                interactionData.put('missingOutput', hasInput && !hasOutput);

                interactionsList.add(interactionData);
            }

            result.put('interactions', interactionsList);

            // Health stats
            Map<String, Object> health = new Map<String, Object>();
            health.put('totalInteractions', interactionIdsFromMessages.size());
            health.put('actualRecords', actualRecordCount);
            health.put('reconstructed', interactionIdsFromMessages.size() - actualRecordCount);
            Integer missingOutputCount = 0;
            for (Map<String, Object> i : interactionsList) {
                if (i.get('missingOutput') == true) missingOutputCount++;
            }
            health.put('missingOutputCount', missingOutputCount);
            if (interactionIdsFromMessages.size() > 0) {
                health.put('healthPct', (actualRecordCount * 100) / interactionIdsFromMessages.size());
            } else {
                health.put('healthPct', 0);
            }
            result.put('health', health);

            // Messages list
            List<Map<String, Object>> messagesList = new List<Map<String, Object>>();
            for (SObject msg : messages) {
                Map<String, Object> md = new Map<String, Object>();
                md.put('messageId', msg.get('ssot__Id__c'));
                md.put('interactionId', msg.get('ssot__AiAgentInteractionId__c'));
                md.put('contentType', msg.get('ssot__AiAgentInteractionMsgContentType__c'));
                md.put('messageType', msg.get('ssot__AiAgentInteractionMessageType__c'));
                md.put('contentText', msg.get('ssot__ContentText__c'));
                md.put('sentTimestamp', msg.get('ssot__MessageSentTimestamp__c'));
                md.put('participantId', msg.get('ssot__AiAgentSessionParticipantId__c'));
                messagesList.add(md);
            }
            result.put('messages', messagesList);

            // Steps list
            List<Map<String, Object>> stepsList = new List<Map<String, Object>>();
            for (SObject step : steps) {
                Map<String, Object> sd = new Map<String, Object>();
                sd.put('stepId', step.get('ssot__Id__c'));
                sd.put('interactionId', step.get('ssot__AiAgentInteractionId__c'));
                sd.put('name', step.get('ssot__Name__c'));
                sd.put('stepType', step.get('ssot__AiAgentInteractionStepType__c'));
                sd.put('startTime', step.get('ssot__StartTimestamp__c'));
                sd.put('endTime', step.get('ssot__EndTimestamp__c'));
                sd.put('errorMessage', step.get('ssot__ErrorMessageText__c'));

                DateTime stepSt = (DateTime)step.get('ssot__StartTimestamp__c');
                DateTime stepEt = (DateTime)step.get('ssot__EndTimestamp__c');
                if (stepSt != null && stepEt != null) {
                    sd.put('elapsedTimeMs', stepEt.getTime() - stepSt.getTime());
                }

                String inputText = (String)step.get('ssot__InputValueText__c');
                String outputText = (String)step.get('ssot__OutputValueText__c');
                sd.put('inputValueText', inputText != null ? inputText.left(5000) : null);
                sd.put('outputValueText', outputText != null ? outputText.left(5000) : null);
                sd.put('hasMoreInput', inputText != null && inputText.length() > 5000);
                sd.put('hasMoreOutput', outputText != null && outputText.length() > 5000);

                stepsList.add(sd);
            }
            result.put('steps', stepsList);

            return JSON.serialize(result);

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving session trace: ' + e.getMessage());
        }
    }

    private class InteractionSortWrapper implements Comparable {
        public String interactionId;
        public DateTime startTime;

        public InteractionSortWrapper(String iid, DateTime st) {
            this.interactionId = iid;
            this.startTime = st;
        }

        public Integer compareTo(Object other) {
            InteractionSortWrapper o = (InteractionSortWrapper)other;
            if (this.startTime == null && o.startTime == null) return 0;
            if (this.startTime == null) return 1;
            if (o.startTime == null) return -1;
            if (this.startTime < o.startTime) return -1;
            if (this.startTime > o.startTime) return 1;
            return 0;
        }
    }
}