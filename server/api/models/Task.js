/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

/**
 * Task.js
 *
 * @description :: A model definition represents a database table/collection.
 * @docs        :: https://sailsjs.com/docs/concepts/models-and-orm/models
 */

/**
 * @swagger
 * components:
 *   schemas:
 *     Task:
 *       type: object
 *       required:
 *         - id
 *         - taskListId
 *         - linkedCardId
 *         - assigneeUserId
 *         - position
 *         - name
 *         - dueDate
 *         - isCompleted
 *         - createdAt
 *         - updatedAt
 *       properties:
 *         id:
 *           type: string
 *           description: Unique identifier for the task
 *           example: "1357158568008091264"
 *         taskListId:
 *           type: string
 *           description: ID of the task list the task belongs to
 *           example: "1357158568008091265"
 *         linkedCardId:
 *           type: string
 *           nullable: true
 *           description: ID of the card linked to the task
 *           example: "1357158568008091266"
 *         assigneeUserId:
 *           type: string
 *           nullable: true
 *           description: ID of the user assigned to the task
 *           example: "1357158568008091267"
 *         position:
 *           type: number
 *           description: Position of the task within the task list
 *           example: 65536
 *         name:
 *           type: string
 *           description: Name/title of the task
 *           example: Write unit tests
 *         dueDate:
 *           type: string
 *           format: date-time
 *           nullable: true
 *           description: Due date for the task
 *           example: 2024-01-01T00:00:00.000Z
 *         isCompleted:
 *           type: boolean
 *           default: false
 *           description: Whether the task is completed
 *           example: false
 *         createdAt:
 *           type: string
 *           format: date-time
 *           nullable: true
 *           description: When the task was created
 *           example: 2024-01-01T00:00:00.000Z
 *         updatedAt:
 *           type: string
 *           format: date-time
 *           nullable: true
 *           description: When the task was last updated
 *           example: 2024-01-01T00:00:00.000Z
 */

module.exports = {
  attributes: {
    //  ╔═╗╦═╗╦╔╦╗╦╔╦╗╦╦  ╦╔═╗╔═╗
    //  ╠═╝╠╦╝║║║║║ ║ ║╚╗╔╝║╣ ╚═╗
    //  ╩  ╩╚═╩╩ ╩╩ ╩ ╩ ╚╝ ╚═╝╚═╝

    position: {
      type: 'number',
      required: true,
    },
    name: {
      type: 'string',
      required: true,
    },
    dueDate: {
      type: 'ref',
      columnName: 'due_date',
    },
    isCompleted: {
      type: 'boolean',
      defaultsTo: false,
      columnName: 'is_completed',
    },

    //  ╔═╗╔╦╗╔╗ ╔═╗╔╦╗╔═╗
    //  ║╣ ║║║╠╩╗║╣  ║║╚═╗
    //  ╚═╝╩ ╩╚═╝╚═╝═╩╝╚═╝

    //  ╔═╗╔═╗╔═╗╔═╗╔═╗╦╔═╗╔╦╗╦╔═╗╔╗╔╔═╗
    //  ╠═╣╚═╗╚═╗║ ║║  ║╠═╣ ║ ║║ ║║║║╚═╗
    //  ╩ ╩╚═╝╚═╝╚═╝╚═╝╩╩ ╩ ╩ ╩╚═╝╝╚╝╚═╝

    taskListId: {
      model: 'TaskList',
      required: true,
      columnName: 'task_list_id',
    },
    linkedCardId: {
      model: 'Card',
      columnName: 'linked_card_id',
    },
    assigneeUserId: {
      model: 'User',
      columnName: 'assignee_user_id',
    },
  },
};
