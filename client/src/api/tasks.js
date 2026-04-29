/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import socket from './socket';

/* Transformers */

export const transformTask = (task) => ({
  ...task,
  ...(task.dueDate && {
    dueDate: new Date(task.dueDate),
  }),
});

export const transformTaskData = (data) => ({
  ...data,
  ...(data.dueDate instanceof Date && {
    dueDate: data.dueDate.toISOString(),
  }),
});

/* Actions */

const createTask = (taskListId, data, headers) =>
  socket
    .post(`/task-lists/${taskListId}/tasks`, transformTaskData(data), headers)
    .then((body) => ({
      ...body,
      item: transformTask(body.item),
    }));

const updateTask = (id, data, headers) =>
  socket.patch(`/tasks/${id}`, transformTaskData(data), headers).then((body) => ({
    ...body,
    item: transformTask(body.item),
  }));

const deleteTask = (id, headers) => socket.delete(`/tasks/${id}`, undefined, headers);

/* Event handlers */

const makeHandleTaskCreate = (next) => (body) => {
  next({
    ...body,
    item: transformTask(body.item),
  });
};

const makeHandleTaskUpdate = makeHandleTaskCreate;

export default {
  createTask,
  updateTask,
  deleteTask,
  makeHandleTaskCreate,
  makeHandleTaskUpdate,
};
