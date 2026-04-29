/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

/**
 * @swagger
 * /cards/{cardId}/attachments:
 *   post:
 *     summary: Create attachment
 *     description: Creates an attachment on a card. Requires board editor permissions.
 *     tags:
 *       - Attachments
 *     operationId: createAttachment
 *     parameters:
 *       - name: cardId
 *         in: path
 *         required: true
 *         description: ID of the card to create the attachment on
 *         schema:
 *           type: string
 *           example: "1357158568008091264"
 *     requestBody:
 *       required: true
 *       content:
 *         multipart/form-data:
 *           schema:
 *             type: object
 *             required:
 *               - type
 *               - name
 *             properties:
 *               type:
 *                 type: string
 *                 enum: [file, link, card]
 *                 description: Type of the attachment
 *                 example: link
 *               file:
 *                 type: string
 *                 format: binary
 *                 description: File to upload
 *               url:
 *                 type: string
 *                 format: url
 *                 maxLength: 2048
 *                 description: URL for the link attachment
 *                 example: https://google.com/search?q=planka
 *               linkedCardId:
 *                 type: string
 *                 description: ID of the card to attach when type is card
 *                 example: "1357158568008091267"
 *               name:
 *                 type: string
 *                 maxLength: 128
 *                 description: Name/title of the attachment
 *                 example: Important Attachment
 *               requestId:
 *                 type: string
 *                 maxLength: 128
 *                 description: Request ID for tracking
 *                 example: req_123456
 *     responses:
 *       200:
 *         description: Attachment created successfully
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               required:
 *                 - item
 *               properties:
 *                 item:
 *                   $ref: '#/components/schemas/Attachment'
 *       400:
 *         $ref: '#/components/responses/ValidationError'
 *       401:
 *         $ref: '#/components/responses/Unauthorized'
 *       403:
 *         $ref: '#/components/responses/Forbidden'
 *       404:
 *         $ref: '#/components/responses/NotFound'
 *       422:
 *         description: Upload or validation error
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               required:
 *                 - code
 *                 - message
 *               properties:
 *                 code:
 *                   type: string
 *                   description: Error code
 *                   example: E_UNPROCESSABLE_ENTITY
 *                 message:
 *                   type: string
 *                   enum:
 *                     - No file was uploaded
 *                     - Url must be present
 *                   description: Specific error message
 *                   example: No file was uploaded
 */

const { isUrl } = require('../../../utils/validators');
const { idInput } = require('../../../utils/inputs');

const Errors = {
  NOT_ENOUGH_RIGHTS: {
    notEnoughRights: 'Not enough rights',
  },
  CARD_NOT_FOUND: {
    cardNotFound: 'Card not found',
  },
  NO_FILE_WAS_UPLOADED: {
    noFileWasUploaded: 'No file was uploaded',
  },
  URL_MUST_BE_PRESENT: {
    urlMustBePresent: 'Url must be present',
  },
  LINKED_CARD_NOT_FOUND: {
    linkedCardNotFound: 'Linked card not found',
  },
};

const buildCardAttachmentValues = async ({ card, list, board, project }) => {
  const cardMemberships = await CardMembership.qm.getByCardId(card.id);
  const userIds = sails.helpers.utils.mapRecords(cardMemberships, 'userId');
  const users = await User.qm.getByIds(userIds);

  return {
    type: Attachment.Types.CARD,
    name: card.name,
    data: {
      cardId: card.id,
      boardId: board.id,
      listId: list.id,
      projectName: project.name,
      boardName: board.name,
      listName: list.name,
      name: card.name,
      isClosed: card.isClosed,
      userIds,
      users: users.map((user) => _.pick(user, ['id', 'name'])),
    },
  };
};

module.exports = {
  inputs: {
    cardId: {
      ...idInput,
      required: true,
    },
    type: {
      type: 'string',
      isIn: Object.values(Attachment.Types),
      required: true,
    },
    url: {
      type: 'string',
      maxLength: 2048,
      custom: isUrl,
    },
    linkedCardId: {
      ...idInput,
    },
    name: {
      type: 'string',
      maxLength: 128,
      required: true,
    },
    requestId: {
      type: 'string',
      isNotEmptyString: true,
      maxLength: 128,
    },
  },

  exits: {
    notEnoughRights: {
      responseType: 'forbidden',
    },
    cardNotFound: {
      responseType: 'notFound',
    },
    noFileWasUploaded: {
      responseType: 'unprocessableEntity',
    },
    uploadError: {
      responseType: 'unprocessableEntity',
    },
    urlMustBePresent: {
      responseType: 'unprocessableEntity',
    },
    linkedCardNotFound: {
      responseType: 'notFound',
    },
  },

  async fn(inputs, exits) {
    const { currentUser } = this.req;

    const { card, list, board, project } = await sails.helpers.cards
      .getPathToProjectById(inputs.cardId)
      .intercept('pathNotFound', () => Errors.CARD_NOT_FOUND);

    const boardMembership = await BoardMembership.qm.getOneByBoardIdAndUserId(
      board.id,
      currentUser.id,
    );

    if (!boardMembership) {
      throw Errors.CARD_NOT_FOUND; // Forbidden
    }

    if (boardMembership.role !== BoardMembership.Roles.EDITOR) {
      throw Errors.NOT_ENOUGH_RIGHTS;
    }

    let data;
    let name = inputs.name;
    let reciprocalAttachmentValues;
    let reciprocalAttachmentPath;
    let existingReciprocalAttachment;

    if (inputs.type === Attachment.Types.FILE) {
      let files;
      try {
        files = await sails.helpers.utils.receiveFile(this.req.file('file'));
      } catch (error) {
        return exits.uploadError(error.message); // TODO: add error
      }

      if (files.length === 0) {
        throw Errors.NO_FILE_WAS_UPLOADED;
      }

      const file = _.last(files);
      data = await sails.helpers.attachments.processUploadedFile(file);
    } else if (inputs.type === Attachment.Types.LINK) {
      if (!inputs.url) {
        throw Errors.URL_MUST_BE_PRESENT;
      }

      data = await sails.helpers.attachments.processLink(inputs.url);
    } else if (inputs.type === Attachment.Types.CARD) {
      if (!inputs.linkedCardId) {
        throw Errors.LINKED_CARD_NOT_FOUND;
      }

      const {
        card: linkedCard,
        list: linkedList,
        board: linkedBoard,
        project: linkedProject,
      } = await sails.helpers.cards
        .getPathToProjectById(inputs.linkedCardId)
        .intercept('pathNotFound', () => Errors.LINKED_CARD_NOT_FOUND);

      if (linkedCard.id === card.id) {
        throw Errors.LINKED_CARD_NOT_FOUND;
      }

      let linkedBoardMembership;
      if (linkedBoard.id !== board.id) {
        linkedBoardMembership = await BoardMembership.qm.getOneByBoardIdAndUserId(
          linkedBoard.id,
          currentUser.id,
        );

        if (!linkedBoardMembership) {
          throw Errors.LINKED_CARD_NOT_FOUND;
        }
      }

      if (!linkedCard.name) {
        throw Errors.LINKED_CARD_NOT_FOUND;
      }

      ({ name, data } = await buildCardAttachmentValues({
        card: linkedCard,
        list: linkedList,
        board: linkedBoard,
        project: linkedProject,
      }));

      const canCreateReciprocalAttachment =
        linkedBoard.id === board.id ||
        linkedBoardMembership.role === BoardMembership.Roles.EDITOR;

      if (canCreateReciprocalAttachment) {
        reciprocalAttachmentValues = await buildCardAttachmentValues({
          card,
          list,
          board,
          project,
        });

        reciprocalAttachmentPath = {
          project: linkedProject,
          board: linkedBoard,
          list: linkedList,
          card: linkedCard,
        };

        const linkedAttachments = await Attachment.qm.getByCardId(linkedCard.id);

        existingReciprocalAttachment = linkedAttachments.find(
          (attachmentItem) =>
            attachmentItem.type === Attachment.Types.CARD &&
            attachmentItem.data &&
            attachmentItem.data.cardId === card.id,
        );
      }
    }

    const values = {
      type: inputs.type,
      name,
      data,
    };

    const attachment = await sails.helpers.attachments.createOne.with({
      project,
      board,
      list,
      values: {
        ...values,
        card,
        creatorUser: currentUser,
      },
      requestId: inputs.requestId,
      request: this.req,
    });

    let reciprocalAttachment = existingReciprocalAttachment;

    if (reciprocalAttachmentValues && !reciprocalAttachment) {
      reciprocalAttachment = await sails.helpers.attachments.createOne.with({
        project: reciprocalAttachmentPath.project,
        board: reciprocalAttachmentPath.board,
        list: reciprocalAttachmentPath.list,
        values: {
          ...reciprocalAttachmentValues,
          card: reciprocalAttachmentPath.card,
          creatorUser: currentUser,
        },
        request: this.req,
      });
    }

    return exits.success({
      item: sails.helpers.attachments.presentOne(attachment),
      included: {
        attachments: reciprocalAttachment
          ? sails.helpers.attachments.presentMany([reciprocalAttachment])
          : [],
      },
    });
  },
};
