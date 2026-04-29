/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import React, { useCallback, useMemo, useState } from 'react';
import PropTypes from 'prop-types';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import { Button, Dropdown, Form, Icon, Input, Menu } from 'semantic-ui-react';
import { FilePicker, Popup } from '../../../lib/custom-ui';

import entryActions from '../../../entry-actions';
import selectors from '../../../selectors';
import { AttachmentTypes } from '../../../constants/Enums';

import styles from './AddAttachmentStep.module.scss';

const CARD_URL_REGEX = /\/cards\/([^/?#]+)/;

const AddAttachmentStep = React.memo(({ onClose }) => {
  const cards = useSelector(selectors.selectCardsExceptCurrentForCurrentBoard) || [];

  const dispatch = useDispatch();
  const [t] = useTranslation();
  const [isCardFormOpened, setIsCardFormOpened] = useState(false);
  const [selectedCardId, setSelectedCardId] = useState(null);
  const [cardUrl, setCardUrl] = useState('');
  const [error, setError] = useState(null);

  const cardOptions = useMemo(
    () =>
      cards.map((card) => ({
        text: card.name,
        value: card.id,
      })),
    [cards],
  );

  const handleFilesSelect = useCallback(
    (files) => {
      files.forEach((file) => {
        dispatch(
          entryActions.createAttachmentInCurrentCard({
            file,
            type: AttachmentTypes.FILE,
            name: file.name,
          }),
        );
      });

      onClose();
    },
    [onClose, dispatch],
  );

  const handleOtherCardsClick = useCallback(() => {
    setIsCardFormOpened(true);
    setError(null);
  }, []);

  const handleCardSelect = useCallback((_, { value }) => {
    setSelectedCardId(value);
    setError(null);
  }, []);

  const handleCardUrlChange = useCallback((_, { value }) => {
    setCardUrl(value);
    setError(null);
  }, []);

  const handleCardSubmit = useCallback(() => {
    const trimmedCardUrl = cardUrl.trim();
    const cardIdFromUrl = trimmedCardUrl.match(CARD_URL_REGEX)?.[1];
    const cardId = selectedCardId || cardIdFromUrl || trimmedCardUrl;
    const card = cards.find((cardItem) => cardItem.id === cardId);

    if (!cardId) {
      setError(t('common.cardNotFound'));
      return;
    }

    dispatch(
      entryActions.createAttachmentInCurrentCard({
        type: AttachmentTypes.CARD,
        linkedCardId: cardId,
        name: card ? card.name : cardId,
      }),
    );

    onClose();
  }, [cards, selectedCardId, cardUrl, dispatch, onClose, t]);

  return (
    <>
      <Popup.Header>
        {t('common.addAttachment', {
          context: 'title',
        })}
      </Popup.Header>
      <Popup.Content>
        <Menu secondary vertical className={styles.menu}>
          <FilePicker multiple onSelect={handleFilesSelect}>
            <Menu.Item className={styles.menuItem}>
              <Icon name="computer" className={styles.menuItemIcon} />
              {t('common.fromComputer', {
                context: 'title',
              })}
            </Menu.Item>
          </FilePicker>
          <Menu.Item className={styles.menuItem} onClick={handleOtherCardsClick}>
            <Icon name="columns" className={styles.menuItemIcon} />
            {t('common.otherCards', {
              context: 'title',
            })}
          </Menu.Item>
        </Menu>
        {isCardFormOpened && (
          <Form className={styles.cardForm} onSubmit={handleCardSubmit}>
            <Dropdown
              fluid
              selection
              search
              options={cardOptions}
              value={selectedCardId}
              placeholder={t('common.searchCards')}
              minCharacters={1}
              noResultsMessage={t('common.noCardsFound')}
              className={styles.cardField}
              onChange={handleCardSelect}
            />
            <Input
              fluid
              value={cardUrl}
              placeholder={t('common.pasteCardUrl')}
              className={styles.cardField}
              onChange={handleCardUrlChange}
            />
            {error && <div className={styles.error}>{error}</div>}
            <Button positive fluid content={t('action.attachCard')} />
          </Form>
        )}
        <hr className={styles.divider} />
        <div className={styles.tip}>
          {t('common.pressPasteShortcutToAddAttachmentFromClipboard')}
        </div>
      </Popup.Content>
    </>
  );
});

AddAttachmentStep.propTypes = {
  onClose: PropTypes.func.isRequired,
};

export default AddAttachmentStep;
